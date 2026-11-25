# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Microsoft's Azure MCP Server (`azmcp`), the self-contained native build npm
# publishes per platform as @azure/mcp-<os>-<arch>. It is a single-file .NET
# app with the runtime bundled, so neither a .NET SDK nor a runtime is
# installed (systemPackages.nix keeps .NET out for its ~1.2 GB closure).
# nixpkgs' azure-mcp is a 3.0.0 beta; this pins the 3.0.0 release.
#
# Darwin only (flake.nix): the Linux builds would need autoPatchelf, and only
# the Macs run it. mcpx.config.nix starts it read-only (`server start
# --read-only`) with Azure CLI credentials only.
#
# To update: set `version` in hashes.json and replace each hash with
#   npm view @azure/mcp-<darwin-arm64|darwin-x64>@<version> dist.integrity
{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
}:

let
  versionData = builtins.fromJSON (builtins.readFile ./hashes.json);
  inherit (versionData) version hashes;

  npmPlatform =
    {
      "aarch64-darwin" = "darwin-arm64";
      "x86_64-darwin" = "darwin-x64";
    }
    .${stdenvNoCC.hostPlatform.system}
      or (throw "Unsupported platform for azure-mcp: ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "azure-mcp";
  inherit version;

  src = fetchurl {
    url = "https://registry.npmjs.org/@azure/mcp-${npmPlatform}/-/mcp-${npmPlatform}-${version}.tgz";
    hash =
      hashes.${stdenvNoCC.hostPlatform.system}
        or (throw "Missing azure-mcp hash for ${stdenvNoCC.hostPlatform.system}");
  };
  # npm tarballs unpack to ./package.
  sourceRoot = "package";

  nativeBuildInputs = [ makeWrapper ];
  dontConfigure = true;
  dontBuild = true;
  # A signed Mach-O: stripping it would invalidate the signature.
  dontStrip = true;

  # dist/ holds resource files beside the binary, and the app looks for them
  # next to itself, so it stays together under libexec and bin/ is a wrapper
  # that execs it by its real path.
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/libexec/azure-mcp"
    cp -R dist/. "$out/libexec/azure-mcp/"
    makeWrapper "$out/libexec/azure-mcp/azmcp" "$out/bin/azmcp"
    runHook postInstall
  '';

  meta = {
    description = "Azure MCP Server (Microsoft's prebuilt native release)";
    homepage = "https://github.com/microsoft/mcp/tree/main/servers/Azure.Mcp.Server";
    license = lib.licenses.mit;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    mainProgram = "azmcp";
    platforms = builtins.attrNames hashes;
  };
}
