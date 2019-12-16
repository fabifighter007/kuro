pactSrc: hackGet: pkgs: self: super: with pkgs.haskell.lib;
let # Working on getting this function upstreamed into nixpkgs, but
    # this actually gets things directly from hackage and doesn't
    # depend on the state of nixpkgs.  Should allow us to have fewer
    # github overrides.
    callHackageDirect = {pkg, ver, sha256}@args:
      let pkgver = "${pkg}-${ver}";
      in self.callCabal2nix pkg (pkgs.fetchzip {
           url = "http://hackage.haskell.org/package/${pkgver}/${pkgver}.tar.gz";
           inherit sha256;
         }) {};

in

(import "${pactSrc}/overrides.nix" pkgs hackGet self super) // {
  pact = dontCheck ( addBuildDepend (self.callCabal2nix "pact" pactSrc {}) pkgs.z3);

  pact-persist = self.callCabal2nix "pact-persist" (builtins.fetchGit {
    url = "ssh://git@github.com/kadena-io/pact-persist.git";
    rev = "5d37a2a435dbec1ee14a92f961779fd3274556c0";
    ref = "master";
  }) {};

  zeromq4-haskell = dontCheck (self.callHackage "zeromq4-haskell" "0.8.0" {});
}
