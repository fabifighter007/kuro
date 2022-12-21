{ pactRef ? "dfac4599b37bbfdb754afa32d25ba4832623277a"
, pactSha ? "03hicg0x77nz4wmwaxnlwf9y0xbypjjdzg3hak756m1qq8vpgc17"
}:
let

pactSrc = builtins.fetchTarball {
  url = "https://github.com/kadena-io/pact/archive/${pactRef}.tar.gz";
  sha256 = pactSha;
};
pactProj = "${pactSrc}/project.nix";

in
  (import pactProj {}).rp.project ({ pkgs, hackGet,... }:
let

gitignore = pkgs.callPackage (pkgs.fetchFromGitHub {
  owner = "siers";
  repo = "nix-gitignore";
  rev = "addd0c9665ddb28e4dd2067dd50a7d4e135fbb29";
  sha256 = "07ngzpvq686jkwkycqg0ary6c07nxhnfxlg76mlm1zv12a5d5x0i";
}) {};

in {
    name = "kadena-umbrella";
    overrides = import ./overrides.nix pactSrc hackGet pkgs;

    packages = {
      kadena = gitignore.gitignoreSource [".git" ".gitlab-ci.yml" "CHANGELOG.md" "README.md"] ./.;
    };

    shellToolOverrides = ghc: super: {
      z3 = pkgs.z3;
      stack = pkgs.stack;
    };

    shells = {
      ghc = ["kadena"];
    };
  })
