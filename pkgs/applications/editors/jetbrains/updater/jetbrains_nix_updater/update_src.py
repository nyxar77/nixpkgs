import json
import platform
import sys
from pathlib import Path
from subprocess import CalledProcessError

from jetbrains_nix_updater.config import UpdaterConfig
from jetbrains_nix_updater.fetcher import VersionInfo
from jetbrains_nix_updater.ides import Ide
from jetbrains_nix_updater.util import convert_hash_to_sri, run_command


class InvalidMetadataException(Exception):
    "raised when required metadata is invalid or malformed."


def prefetch_intellij_community(variant: str, version: str) -> tuple[str, Path]:
    print("[*] Prefetching IntelliJ community source code...")
    prefetch = run_command(
        [
            "nix-prefetch-url",
            "--print-path",
            "--unpack",
            "--name",
            "source",
            "--type",
            "sha256",
            f"https://github.com/JetBrains/intellij-community/archive/refs/tags/{variant}/{version}.tar.gz",
        ]
    )
    parts = prefetch.split()

    hash = convert_hash_to_sri(parts[0])
    out_path = parts[1]

    return (hash, Path(out_path))


def prefetch_android(variant: str, version: str) -> str:
    print("[*] Prefetching Android plugin source code...")
    prefetch = run_command(
        [
            "nix-prefetch-url",
            "--unpack",
            "--name",
            "source",
            "--type",
            "sha256",
            f"https://github.com/JetBrains/android/archive/refs/tags/{variant}/{version}.tar.gz",
        ]
    )
    return convert_hash_to_sri(prefetch)


def generate_restarter_hash(config: UpdaterConfig, root_path: Path) -> str:
    print("[*] Generating restarter Cargo hash...")
    root_name = root_path.name
    return run_command(
        [
            "nurl",
            "--expr",
            f"""
        (import {config.nixpkgs_root} {{}}).rustPlatform.buildRustPackage {{
            name = "restarter";
            src = {root_path};
            sourceRoot = "{root_name}/native/restarter";
            cargoHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        }}
    """,
        ]
    )


def get_bazel_version(ij_root_path: Path) -> tuple[str, str]:
    with (ij_root_path / ".bazelversion").open("r") as f:
        version_string = f.read().strip()
    if not version_string.startswith("JetBrains/") or "-" not in version_string:
        raise InvalidMetadataException(
            f"Unexpected .bazelversion format: {version_string!r}"
        )
    bazel_base_version, bazel_patches_version = version_string.removeprefix(
        "JetBrains/"
    ).split("-", 1)
    print(
        f"[i] Detected Bazel version: {bazel_base_version} - JetBrains patches: {bazel_patches_version}"
    )
    return bazel_base_version, bazel_patches_version


def prefetch_bazel_src(bazel_base_version: str) -> str:
    print(f"[*] Prefetching Bazel {bazel_base_version} source...")
    prefetch = run_command(
        [
            "nix-prefetch-url",
            "--unpack",
            "--name",
            "source",
            "--type",
            "sha256",
            f"https://github.com/bazelbuild/bazel/releases/download/{bazel_base_version}/bazel-{bazel_base_version}-dist.zip",
        ]
    )
    return convert_hash_to_sri(prefetch)


def prefetch_jb_bazel_patches_src(
    bazel_base_version: str, bazel_patches_version: str
) -> tuple[str, Path]:
    tag = f"{bazel_base_version}-{bazel_patches_version}"
    print(f"[*] Prefetching JetBrains Bazel patches {tag} source...")
    prefetch = run_command(
        [
            "nix-prefetch-url",
            "--print-path",
            "--unpack",
            "--name",
            "source",
            "--type",
            "sha256",
            f"https://github.com/JetBrains/bazel/archive/refs/tags/{tag}.tar.gz",
        ]
    )
    parts = prefetch.split()

    hash = convert_hash_to_sri(parts[0])
    out_path = parts[1]

    return hash, Path(out_path)


def get_jb_bazel_patches_files(patches_outpath: Path) -> list[str]:
    # These patches are known to cause issues and are not relevant for the build using Nix, so we skip them
    skip_patches = {"0015-Allow-platform-specific-startup-bazelrc-flags.patch"}

    patches_dir = patches_outpath / "patches"
    return sorted(
        p.name for p in patches_dir.glob("*.patch") if p.name not in skip_patches
    )


def latest_commit_sha(repo_url: str, ref: str = "HEAD") -> str:
    out = run_command(["git", "ls-remote", repo_url, ref])
    return out.split()[0]


def get_latest_bazel_registry() -> tuple[str, str]:
    print("[*] Getting latest Bazel central registry commit...")
    commit = latest_commit_sha("https://github.com/bazelbuild/bazel-central-registry")
    print(f"[*] Prefetching Bazel central registry commit {commit}...")
    prefetch = run_command(
        [
            "nix-prefetch-url",
            "--unpack",
            "--name",
            "source",
            "--type",
            "sha256",
            f"https://github.com/bazelbuild/bazel-central-registry/archive/{commit}.tar.gz",
        ]
    )
    return commit, convert_hash_to_sri(prefetch)


def generate_bazel_deps_hash(config: UpdaterConfig, ide: Ide) -> str:
    print(
        f"[*] Generating Bazel repoCacheHash for {ide.name} (this can take a long time)..."
    )
    return run_command(
        [
            "nurl",
            "--expr",
            f'(import {config.nixpkgs_root} {{ config.allowInsecurePredicate = _: true; }})."{ide.name}".src.bazelDeps',
        ]
    )


def run_src_update(ide: Ide, info: VersionInfo, config: UpdaterConfig) -> bool:
    variant = ide.name.removesuffix("-oss")
    if variant.endswith("idea"):
        variant = variant.removeprefix("intellij-")

    try:
        intellij_hash, intellij_outpath = prefetch_intellij_community(
            variant, info.version
        )
        android_hash = prefetch_android(variant, info.version)
    except CalledProcessError as e:
        print(
            f"[!] Unable to fetch sources for version {info.version} (stderr: {e.stderr}). "
            f"This probably means, that JetBrains has not published a source release yet for this version. "
            f"Check: https://github.com/JetBrains/intellij-community/releases and https://github.com/JetBrains/android/tags",
            file=sys.stderr,
        )
        print(f"[!] Skipping update of {ide.name}.", file=sys.stderr)
        return False

    restarter_hash = generate_restarter_hash(config, intellij_outpath)
    bazel_base_version, bazel_patches_version = get_bazel_version(intellij_outpath)
    bazel_base_hash = prefetch_bazel_src(bazel_base_version)
    bazel_patches_hash, bazel_patches_outpath = prefetch_jb_bazel_patches_src(
        bazel_base_version, bazel_patches_version
    )
    bazel_patches_names = get_jb_bazel_patches_files(bazel_patches_outpath)
    registry_rev, registry_hash = get_latest_bazel_registry()

    source_args_path = ide.package_dir / "source_args.json"
    source_args = {
        "version": info.version,
        "buildNumber": info.build_number,
        "buildType": variant,
        "ideaHash": intellij_hash,
        "androidHash": android_hash,
        "restarterHash": restarter_hash,
    }

    bazel_args_path = ide.package_dir / "bazel_args.json"
    bazel_args = {
        "base": {
            "version": bazel_base_version,
            "hash": bazel_base_hash,
        },
        "jbPatches": {
            "version": bazel_patches_version,
            "hash": bazel_patches_hash,
            "names": bazel_patches_names,
        },
        "registry": {
            "rev": registry_rev,
            "hash": registry_hash,
        },
        "repoCacheHash": "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    }

    print(f"[*] Writing mkJetBrainsSource args to {source_args_path}")
    print(f"[*] Writing Bazel args to {bazel_args_path}")
    if not config.dry_run:
        with source_args_path.open("w") as f:
            json.dump(source_args, f, indent=2)
            f.write("\n")
        with bazel_args_path.open("w") as f:
            json.dump(bazel_args, f, indent=2)
            f.write("\n")

    if not config.no_bazel_deps:
        if config.dry_run:
            print(
                f"[D] --dry-run: skipping repoCacheHash generation for {ide.name}",
                file=sys.stderr,
            )
        elif platform.system() != "Linux" or platform.machine() != "x86_64":
            print(
                f"[!] Skipping repoCacheHash generation for {platform.machine()}-{platform.system().lower()}: "
                f"source builds currently only support x86_64-linux.",
                file=sys.stderr,
            )
        else:
            bazel_args["repoCacheHash"] = generate_bazel_deps_hash(config, ide)
            with bazel_args_path.open("w") as f:
                json.dump(bazel_args, f, indent=2)
                f.write("\n")

    return True
