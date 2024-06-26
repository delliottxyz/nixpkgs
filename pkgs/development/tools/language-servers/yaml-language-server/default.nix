{ lib
, mkYarnPackage
, fetchYarnDeps
, fetchFromGitHub
}:

mkYarnPackage rec {
  pname = "yaml-language-server";
  version = "1.15.0";

  src = fetchFromGitHub {
    owner = "redhat-developer";
    repo = "yaml-language-server";
    rev = version;
    hash = "sha256-Y3Q/y9UIiy7US8Jl4vxT0Pfw8h3hiXK+Cu9TEQHyAaA=";
  };

  packageJSON = ./package.json;
  offlineCache = fetchYarnDeps {
    yarnLock = "${src}/yarn.lock";
    hash = "sha256-zHcxZ4VU6CGux72Nsy0foU4gFshK1wO/LTfnwOoirmg=";
  };

  buildPhase = ''
    runHook preBuild

    export HOME=$(mktemp -d)
    yarn --offline build

    runHook postBuild
  '';

  meta = {
    changelog = "https://github.com/redhat-developer/yaml-language-server/blob/${src.rev}/CHANGELOG.md";
    description = "Language Server for YAML Files";
    homepage = "https://github.com/redhat-developer/yaml-language-server";
    license = lib.licenses.mit;
    mainProgram = "yaml-language-server";
    maintainers = [ ];
  };
}
