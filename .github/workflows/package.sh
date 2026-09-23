#!/bin/sh
set -eu

target="$1"
asset="$2"
tag="$3"
version="${tag#v}"
pkgdir="blackcat-${asset}-${version}"

if [ -f "target/${target}/release/blackcat" ]; then
    bin="target/${target}/release/blackcat"
else
    bin="target/release/blackcat"
fi

mkdir -p dist "$pkgdir"
cp "$bin" "$pkgdir/blackcat"
tar -czf "dist/${pkgdir}.tgz" "$pkgdir"
rm -rf "$pkgdir"
