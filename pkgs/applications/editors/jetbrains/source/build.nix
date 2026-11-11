# TODO: This is currently only supported for x86_64-linux
{
  # keep-sorted start
  alsa-lib,
  autoPatchelfHook,
  bash,
  callPackage,
  coreutils,
  fetchurl,
  fetchzip,
  fsnotifier,
  glibc,
  gnugrep,
  jetbrains,
  jetbrains-libdbm,
  lib,
  libpanel,
  libxcrypt-legacy,
  libxi,
  libxml2_13,
  libxrender,
  libxtst,
  linkFarm,
  maven,
  ncurses,
  python3,
  rustPlatform,
  stdenv,
  xz,
  zlib,
  # keep-sorted end
}:
{
  version,
  buildNumber,
  buildType,
  ideaHash,
  androidHash,
  restarterHash,
  bazelConfig,
}:
let
  # The build number with the patch part removed. This is required for the build, since the build appends a patch part itself for plugins, otherwise
  # they fail with an invalid semver version ("The plugin build number 261.25134.95.20260601 is expected to match the Semantic Versioning")
  buildNumberMinor = builtins.concatStringsSep "." (lib.init (lib.splitString "." buildNumber));

  jbr = jetbrains.jdk-no-jcef-21;

  bazelArgs = [
    "--features=-module_maps"
    "--host_features=-module_maps"
  ];

  patches = [
    ../patches/no-download.patch
    ../patches/disable-sbom-generation.patch
  ];

  bazelDeps = callPackage ./bazel-deps.nix { } {
    inherit
      version
      buildType
      ideaHash
      androidHash
      bazelConfig
      ;
    commandArgs = bazelArgs;
  };

  inherit (bazelDeps)
    bazel
    src
    androidSrc
    registry
    bazelTarget
    ;

  # Use the libdbm version in our src.
  libdbm = jetbrains-libdbm.overrideAttrs {
    inherit src version;
  };

  restarter = rustPlatform.buildRustPackage {
    pname = "restarter";
    version = buildNumber;
    inherit src;
    sourceRoot = "${src.name}/native/restarter";

    cargoHash = restarterHash;

    # Allow static linking
    buildInputs = [
      # keep-sorted start
      glibc
      glibc.static
      # keep-sorted end
    ];
  };

  # These maven artifacts are downloaded by the JPS installer and not provided via Bazel (or at least JPS doesn't pick them up).
  artefacts = [
    {
      repo = "repo.maven.apache.org/maven2";
      path = "org/apache/maven/archetype/archetype-catalog/2.2/archetype-catalog-2.2.jar";
      hash = "sha256-ES4G5qzBQFrTulGEQug10dQnWO8x8Lu9syqh4VoX0Q8=";
    }
    {
      repo = "repo.maven.apache.org/maven2";
      path = "org/apache/maven/shared/maven-dependency-tree/1.2/maven-dependency-tree-1.2.jar";
      hash = "sha256-27jFPMwLFqndg3DW595jECRoyu2sHl+i60GDGaaHUpM=";
    }
    {
      repo = "repo.maven.apache.org/maven2";
      path = "org/sonatype/nexus/nexus-indexer-artifact/1.0.1/nexus-indexer-artifact-1.0.1.jar";
      hash = "sha256-FxA1dAMi+WvYwVXPtgUJYt1h15dqSUwKrG1Gs8gxdMQ=";
    }
    {
      repo = "repo.maven.apache.org/maven2";
      path = "org/apache/lucene/lucene-core/2.4.1/lucene-core-2.4.1.jar";
      hash = "sha256-uF1sKmtMKekPp8XZSyH+eW+caFeHAmi1aQR2USa65xg=";
    }
    {
      repo = "repo.maven.apache.org/maven2";
      path = "org/apache/maven/archetype/archetype-descriptor/2.2/archetype-descriptor-2.2.jar";
      hash = "sha256-Fi/wzIBEUwfeBfXgzpwBTozSLPvS7WEK45gG5FksUlU=";
    }
    {
      repo = "repo.maven.apache.org/maven2";
      path = "org/apache/maven/archetype/archetype-common/2.2/archetype-common-2.2.jar";
      hash = "sha256-OgCngVeoL/93gzR2QlVkJYUSdEPgs9pWvNtvig+RAiA=";
    }
    {
      repo = "repo.maven.apache.org/maven2";
      path = "org/sonatype/nexus/nexus-indexer/3.0.4/nexus-indexer-3.0.4.jar";
      hash = "sha256-nUOijQdYkU/c6iikNmAawm0Go7VdKDu2vgMhzNNjGlg=";
    }
    {
      repo = "repo.maven.apache.org/maven2";
      path = "com/fasterxml/jackson/core/jackson-core/2.19.0/jackson-core-2.19.0.jar";
      hash = "sha256-2o6Fm6yUh0UoEWol8gxoVg5Ch6y/J2KHEbik+WsChDA=";
    }
  ];
  mkRepoEntry = entry: {
    name = ".m2/repository/" + entry.path;
    path = fetchurl {
      urls = [
        "https://cache-redirector.jetbrains.com/${entry.repo}/${entry.path}"
        "https://${entry.repo}/${entry.path}"
      ];
      # Do not try to retry 4xx errors
      curlOptsList = [ "--no-retry-all-errors" ];
      hash = entry.hash;
    };
  };
  mvnRepo = linkFarm "intellij-jps-deps" (map mkRepoEntry artefacts);

  xplat-launcher = fetchzip {
    urls = [
      "https://cache-redirector.jetbrains.com/intellij-dependencies/org/jetbrains/intellij/deps/launcher/242.22926/launcher-242.22926.tar.gz"
      "https://packages.jetbrains.team/maven/p/ij/intellij-dependencies/org/jetbrains/intellij/deps/launcher/242.22926/launcher-242.22926.tar.gz"
    ];
    hash = "sha256-ttrQZUbBvvyH1BSVt1yWOoD82WwRi/hkoRfrsdCjwTA=";
    stripRoot = false;
  };

  pname = "${buildType}-oss";

  autoPatchelfVendorDirs = [
    "toolchains_llvm++llvm+llvm_toolchain_llvm"
    "llvm+"
    "rules_python++python+python_3_11_x86_64-unknown-linux-gnu"
    "rules_java++toolchains+remote_java_tools_linux"
    "+jbr_toolchains+remotejbr21_linux"
    "+jbr_toolchains+remotejbr25_linux"
    "rules_java++toolchains+remotejdk21_linux"
    "rules_java++toolchains+remotejdk25_linux"
  ];
in
callPackage ../../../../by-name/ba/bazel_9/build-support/bazelDerivation.nix { } {
  inherit
    version
    src
    bazel
    registry
    patches
    ;
  name = "${pname}-${version}.tar.gz";

  postUnpack = ''
    ln -s ${androidSrc} "$sourceRoot/android"
  '';

  buildInputs = lib.optional (!stdenv.hostPlatform.isDarwin) autoPatchelfHook ++ [
    # keep-sorted start
    alsa-lib
    libpanel
    libxcrypt-legacy
    libxi
    libxml2_13
    libxrender
    libxtst
    ncurses
    python3
    stdenv.cc
    xz
    zlib
    # keep-sorted end
  ];

  nativeBuildInputs = [
    # keep-sorted start
    bash
    stdenv.cc
    # keep-sorted end
  ];

  # autoPatchelf will cross-link different jdks if run on top-level, we'll run manually
  dontAutoPatchelf = true;

  bazelRepoCache = bazelDeps;
  command = "build";
  targets = [ bazelTarget ];
  commandArgs = bazelArgs ++ [ "--vendor_dir=vendor_dir" ];

  bazelPreBuild = ''
    ## BAZEL PATCHES
    # Replace upstream's lockfile with the refreshed one from bazelDeps
    install -m 644 ${bazelDeps}/MODULE.bazel.lock MODULE.bazel.lock

    # Patch the version number (remove JetBrains/ prefix)
    substituteInPlace .bazelversion --replace-fail "JetBrains/" ""
    if [ -f platform/build-scripts/bazel/.bazelversion ]; then
      substituteInPlace platform/build-scripts/bazel/.bazelversion --replace-fail "JetBrains/" ""
    fi

    mkdir vendor_dir
    ${bazel}/bin/bazel --batch vendor \
      --vendor_dir=vendor_dir \
      --registry=file://${registry} \
      --repository_cache=repo_cache \
      --repo_contents_cache= \
      ${lib.escapeShellArgs bazelArgs} \
      ${bazelTarget}

    function sedVerbose() {
      local path=$1; shift;
      sed -i".bak-nix" "$path" "$@"
      diff -U0 "$path.bak-nix" "$path" | sed "s/^/  /" || true
      rm -f "$path.bak-nix"
    }
    ${gnugrep}/bin/grep -rlZ --include="*.bzl" --include "BUILD.bazel" --include "BUILD" /bin/bash vendor_dir \
      | while IFS="" read -r -d "" path; do
          echo "$path"
          sedVerbose "$path" \
            -e 's!/usr/bin/bash!${bash}/bin/bash!g' \
            -e 's!/bin/bash!${bash}/bin/bash!g'
      done;
    ${gnugrep}/bin/grep -rlZ --include="*.bzl" --include "BUILD.bazel" --include "BUILD" --include "java_stub_template.txt" /usr/bin/env vendor_dir \
      | while IFS="" read -r -d "" path; do
          echo "$path"
          sedVerbose "$path" \
            -e 's!/usr/bin/env bash!${bash}/bin/bash!g' \
            -e 's!/usr/bin/env!${coreutils}/bin/env!g'
      done;

    # autoPatchelf may fail on some paths without permissions change
    chmod -R u+w vendor_dir
    ${builtins.concatStringsSep "\n" (
      map (d: "if [ -d \"vendor_dir/${d}\" ]; then autoPatchelf \"vendor_dir/${d}\"; fi") autoPatchelfVendorDirs
    )}

    ## INSTALLER PATCHES
    cp ${restarter}/bin/restarter bin/linux/amd64/restarter
    cp ${fsnotifier}/bin/fsnotifier bin/linux/amd64/fsnotifier
    cp ${libdbm}/lib/libdbm.so bin/linux/amd64/libdbm.so

    substituteInPlace \
      platform/build-scripts/downloader/src/org/jetbrains/intellij/build/dependencies/JdkDownloader.kt \
      --replace-fail 'JDK_PATH_HERE' '${jbr}/lib/openjdk'
    # Regarding brokenPlugins.json:
    #  We provide an empty brokenPlugins.json because the original file is 2.8 MB in size and can't be reliably
    #  downloaded without hash changes. The file is not important for the IDEs to function properly.
    substituteInPlace \
      platform/build-scripts/src/org/jetbrains/intellij/build/impl/brokenPlugins.kt \
      --replace-fail 'BROKEN_PLUGINS_HERE' '${./brokenPlugins.json}'
    substituteInPlace \
      platform/build-scripts/src/org/jetbrains/intellij/build/impl/LinuxDistributionBuilder.kt \
      --replace-fail 'XPLAT_LAUNCHER_PREBUILT_PATH_HERE' '${xplat-launcher}'

    substituteInPlace \
      build/deps/src/org/jetbrains/intellij/build/impl/BundledMavenDownloader.kt \
      --replace-fail 'MAVEN_REPO_HERE' '${mvnRepo}/.m2/repository/' \
      --replace-fail 'MAVEN_PATH_HERE' '${maven}/maven'

    echo '${buildNumberMinor}.SNAPSHOT' > build.txt
  '';

  installPhase = ''
    runHook preInstall

    ${bazel}/bin/bazel --batch run \
      --registry=file://${registry} \
      --repository_cache=repo_cache \
      --repo_contents_cache= \
      --vendor_dir=vendor_dir \
      ${lib.escapeShellArgs bazelArgs} \
      ${bazelTarget} \
      -- \
      --jvm_flag=-Dbuild.number=${buildNumberMinor} \
      --jvm_flag=-Dintellij.build.target.os=current \
      --jvm_flag=-Dintellij.build.target.arch=current

    mv out/*/artifacts/*-no-jbr.tar.gz $out

    runHook postInstall
  '';

  passthru = {
    inherit
      version
      buildNumber
      # this is jetbrains-libdbm but using the sources from the IDE build.
      libdbm
      fsnotifier
      bazelDeps
      ;
    bazelRepoCache = bazelDeps;
  };

  meta.platforms = [ "x86_64-linux" ];
}
