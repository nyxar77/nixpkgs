{
  # keep-sorted start
  bazel_9,
  fetchFromGitHub,
  fetchzip,
  # keep-sorted end
}:
{
  base,
  jbPatches,
}:
let
  version = "${base.version}-${jbPatches.version}";
  patchesSrc = fetchFromGitHub {
    owner = "JetBrains";
    repo = "bazel";
    tag = version;
    hash = jbPatches.hash;
  };
in
(bazel_9.override { inherit version; }).overrideAttrs (oldAttrs: {
  src = fetchzip {
    url = "https://github.com/bazelbuild/bazel/releases/download/${base.version}/bazel-${base.version}-dist.zip";
    hash = base.hash;
    stripRoot = false;
  };

  patches = oldAttrs.patches ++ map (name: "${patchesSrc}/patches/${name}") jbPatches.names;
})
