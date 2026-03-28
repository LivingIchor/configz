# Maintainer: Malachi <livingichor@gmail.com>
pkgname=configz-git
pkgver=0.1
pkgrel=1
pkgdesc="A dotfile manager using a bare git repo with automatic file watching"
arch=('x86_64')
url="https://github.com/LivingIchor/configz"
license=('MIT')
depends=('libgit2' 'git' 'socat' 'jq')
makedepends=('git' 'zig-nightly-bin')
checkdepends=('socat' 'jq' 'git')
provides=('configz')
conflicts=('configz')
backup=()
source=(
    "${pkgname}::git+${url}.git"
    "zig-clap.tar.gz::https://github.com/Hejsil/zig-clap/archive/refs/heads/master.tar.gz"
)
sha256sums=(
    'SKIP'
    'SKIP'
)

pkgver() {
    cd "${pkgname}"
    printf "r%s.%s" "$(git rev-list --count HEAD)" "$(git rev-parse --short HEAD)"
}

prepare() {
    cd "${pkgname}"

    local cache_dir="${srcdir}/zig-cache"
    mkdir -p "${cache_dir}"

    # Compute the hash of the vendored tarball and update build.zig.zon
    # in place so zig build sees a matching hash regardless of when the
    # tarball was originally fetched.
    local computed_hash
    computed_hash=$(zig fetch --global-cache-dir "${cache_dir}" \
        "${srcdir}/zig-clap.tar.gz")

    sed -i "s|\.hash = \"clap-[^\"]*\"|.hash = \"${computed_hash}\"|" \
        build.zig.zon
}

build() {
    cd "${pkgname}"
    zig build \
        --global-cache-dir "${srcdir}/zig-cache" \
        -Doptimize=ReleaseSafe
}

check() {
    cd "${pkgname}"

    # Set up an isolated runtime dir for the test suite
    local test_runtime
    test_runtime=$(mktemp -d)
    trap 'rm -rf "$test_runtime"' RETURN

    XDG_RUNTIME_DIR="${test_runtime}" \
        bash test_configz.sh \
            "${srcdir}/${pkgname}/zig-out/bin/configzd" \
            "${srcdir}/${pkgname}/cli/configz.sh"
}

package() {
    cd "${pkgname}"

    # Daemon binary
    install -Dm755 zig-out/bin/configzd "${pkgdir}/usr/bin/configzd"

    # CLI script
    install -Dm755 cli/configz.sh "${pkgdir}/usr/bin/configz"

    # systemd user service
    install -Dm644 /dev/stdin "${pkgdir}/usr/lib/systemd/user/configzd.service" <<EOF
[Unit]
Description=configzd dotfile manager daemon
After=default.target

[Service]
Type=simple
ExecStart=/usr/bin/configzd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

    # License
    install -Dm644 LICENSE "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
}
