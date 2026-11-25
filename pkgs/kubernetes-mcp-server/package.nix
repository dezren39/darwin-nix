# SPDX-License-Identifier: MIT OR Apache-2.0
#
# containers/kubernetes-mcp-server: a Go MCP server that talks to the
# Kubernetes API directly (no kubectl). Not in nixpkgs; this installs the
# prebuilt binary its npm release publishes per platform as
# kubernetes-mcp-server-<os>-<arch>, as pkgs/codedb does for codedb.
#
# mcpx.config.nix runs it with config.toml from this package: read-only, the
# config and core toolsets plus helm, and Secrets denied. Its kubeconfig is
# ~/.kube/config, whose AKS users run `kubelogin get-token --login azurecli`,
# so that server's PATH must reach kubelogin and az.
#
# To update: set `version` in hashes.json and replace each hash with
#   npm view kubernetes-mcp-server-<darwin-arm64|darwin-amd64>@<version> dist.integrity
{
  lib,
  stdenvNoCC,
  fetchurl,
}:

let
  versionData = builtins.fromJSON (builtins.readFile ./hashes.json);
  inherit (versionData) version hashes;

  npmPlatform =
    {
      "aarch64-darwin" = "darwin-arm64";
      "x86_64-darwin" = "darwin-amd64";
    }
    .${stdenvNoCC.hostPlatform.system}
      or (throw "Unsupported platform for kubernetes-mcp-server: ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "kubernetes-mcp-server";
  inherit version;

  src = fetchurl {
    url = "https://registry.npmjs.org/kubernetes-mcp-server-${npmPlatform}/-/kubernetes-mcp-server-${npmPlatform}-${version}.tgz";
    hash =
      hashes.${stdenvNoCC.hostPlatform.system}
        or (throw "Missing kubernetes-mcp-server hash for ${stdenvNoCC.hostPlatform.system}");
  };
  # npm tarballs unpack to ./package.
  sourceRoot = "package";

  dontConfigure = true;
  dontBuild = true;
  # A signed Mach-O: stripping it would invalidate the signature.
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 "bin/kubernetes-mcp-server-${npmPlatform}" "$out/bin/kubernetes-mcp-server"
    install -Dm644 ${./config.toml} "$out/share/kubernetes-mcp-server/config.toml"
    runHook postInstall
  '';

  meta = {
    description = "Kubernetes MCP server (containers/kubernetes-mcp-server prebuilt release)";
    homepage = "https://github.com/containers/kubernetes-mcp-server";
    license = lib.licenses.asl20;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    mainProgram = "kubernetes-mcp-server";
    platforms = builtins.attrNames hashes;
  };
}
