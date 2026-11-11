{
  # keep-sorted start
  callPackage,
  fetchFromGitHub,
  # keep-sorted end
}:
{
  version,
  buildType ? "idea",
  ideaHash,
  androidHash,
  bazelConfig,
  patches ? [ ],
  bazelPreBuild ? "",
  commandArgs ? [ ],
}:
let
  bazel = callPackage ./bazel.nix { } {
    inherit (bazelConfig) base jbPatches;
  };
  src = fetchFromGitHub {
    owner = "JetBrains";
    repo = "intellij-community";
    tag = "${buildType}/${version}";
    hash = ideaHash;
  };
  androidSrc = fetchFromGitHub {
    owner = "JetBrains";
    repo = "android";
    tag = "${buildType}/${version}";
    hash = androidHash;
  };
  registry = fetchFromGitHub {
    owner = "bazelbuild";
    repo = "bazel-central-registry";
    inherit (bazelConfig.registry) rev hash;
  };
  bazelTarget =
    if buildType == "pycharm" then
      "@community//python/build:i_build_target"
    else
      "//build:i_build_target";
in
callPackage ../../../../by-name/ba/bazel_9/build-support/bazelDerivation.nix { } {
  name = "${buildType}-oss-${version}-bazel-deps";
  inherit
    version
    src
    bazel
    registry
    patches
    ;

  postUnpack = ''
    ln -s ${androidSrc} "$sourceRoot/android"
  '';

  command = "fetch";
  targets = [ bazelTarget ];
  commandArgs = [
    "--repository_cache=repo_cache"
    "--repo_contents_cache="
    "--lockfile_mode=update"
  ]
  ++ commandArgs;
  bazelPreBuild = ''
    mkdir repo_cache
    substituteInPlace .bazelversion --replace-fail "JetBrains/" ""
    if [ -f platform/build-scripts/bazel/.bazelversion ]; then
      substituteInPlace platform/build-scripts/bazel/.bazelversion --replace-fail "JetBrains/" ""
    fi
    ${bazelPreBuild}
  '';

  # Keep downloaded bytes intact: ELF and shebang patching belongs to the
  # subsequent offline build, after Bazel has verified the downloaded hashes.
  dontFixup = true;
  installPhase = ''
    mkdir -p $out
    cp -r repo_cache $out/
    cp MODULE.bazel.lock $out/
  '';

  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
  outputHash = bazelConfig.repoCacheHash;

  passthru = {
    inherit
      bazel
      src
      androidSrc
      registry
      bazelTarget
      ;
  };
  meta.platforms = [ "x86_64-linux" ];
}
