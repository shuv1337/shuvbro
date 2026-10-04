#!/usr/bin/env bash
# fm-install-runner-tools.sh - pinned user-local tools for CI runners.
#
# Installs pinned binaries into <dest>/bin with no root, apt, or sudo.
# Ruby is the ruby-builder release (the same family setup-ruby uses).
# Chrome is Chrome for Testing's linux64 headless shell.
# ps and lsof are the Ubuntu 24.04 noble release binaries of procps and lsof.
# Those projects do not publish their own linux release binaries, so the
# script downloads the noble debs from archive.ubuntu.com, checks the pinned
# SHA-256, and extracts them with dpkg-deb. Shared libraries those binaries
# need are pinned the same way and are visible only through the wrappers'
# LD_LIBRARY_PATH, not the job-wide library path.
#
# Usage:
#   fm-install-runner-tools.sh <destination-directory> <tool>...
# Tools: ruby ps lsof chrome
set -eu

die() {
  printf 'fm-install-runner-tools.sh: %s\n' "$*" >&2
  exit 1
}

if [ "$#" -lt 2 ]; then
  die "usage: fm-install-runner-tools.sh <destination-directory> <tool>..."
fi

DESTINATION=$1
shift
TOOLS=" $* "

tool_selected() {
  case "$TOOLS" in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

for tool in "$@"; do
  case "$tool" in
    ruby|ps|lsof|chrome) ;;
    *) die "unknown tool: $tool" ;;
  esac
done

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v tar >/dev/null 2>&1 || die "tar is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb is required to extract pinned debs"
if command -v sha256sum >/dev/null 2>&1; then
  SHA_TOOL=sha256sum
elif command -v shasum >/dev/null 2>&1; then
  SHA_TOOL=shasum
else
  die "need sha256sum or shasum to verify downloads"
fi

mkdir -p "$DESTINATION/bin" "$DESTINATION/payload"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-runner-tools.XXXXXX")
SEEN="$TMP/seen"
: > "$SEEN"
trap 'rm -rf "$TMP"' EXIT

sha256_file() {
  if [ "$SHA_TOOL" = sha256sum ]; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

download() {
  url=$1
  dest=$2
  attempt=1
  while ! curl -fsSL "$url" -o "$dest"; do
    [ "$attempt" -lt 6 ] || die "download failed after 6 attempts: $url"
    printf 'fm-install-runner-tools.sh: download attempt %s failed; retrying\n' "$attempt" >&2
    sleep $((1 << (attempt - 1)))
    attempt=$((attempt + 1))
  done
}

extract_one() {
  kind=$1
  file=$2
  case "$kind" in
    deb)
      dpkg-deb -x "$file" "$DESTINATION/payload"
      ;;
    tar)
      mkdir -p "$DESTINATION/payload/ruby"
      tar -xzf "$file" -C "$DESTINATION/payload/ruby"
      ;;
    zip)
      # zipfile does not apply the archive's executable bits on its own.
      python3 - "$file" "$DESTINATION/payload" <<'PY'
import os, sys, zipfile
archive, dest = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(archive) as zf:
    zf.extractall(dest)
    for info in zf.infolist():
        mode = info.external_attr >> 16
        if mode:
            os.chmod(os.path.join(dest, info.filename), mode)
PY
      ;;
    *)
      die "unknown archive kind: $kind"
      ;;
  esac
}

while read -r group kind sha url; do
  case "$group" in
    ''|\#*) continue ;;
  esac
  tool_selected "$group" || continue
  if grep -Fxq "$url" "$SEEN"; then
    continue
  fi
  printf '%s\n' "$url" >> "$SEEN"
  archive="$TMP/$(basename "$url")"
  download "$url" "$archive"
  actual=$(sha256_file "$archive")
  [ "$actual" = "$sha" ] || die "checksum mismatch for $url (expected $sha, got $actual)"
  extract_one "$kind" "$archive"
done <<'PINS'
chrome deb 0b2ab64af92a71e3d1a35e3c819880ee28d04bfac81360df68ae8d8e9663ebd2 http://archive.ubuntu.com/ubuntu/pool/main/libx/libxcb/libxcb-xfixes0_1.15-1ubuntu2_amd64.deb
chrome deb 0b60996bc18fa1545e60a47bb0fe1a7f360ec06fe62ba35fb8d8ba2a54e62166 http://archive.ubuntu.com/ubuntu/pool/main/libd/libdrm/libdrm-common_2.4.125-1ubuntu0.1~24.04.2_all.deb
chrome deb 0c26896193480d9dbb055e85e8ddfb9c9f34cf19afee340987cd6311e2886fc1 http://archive.ubuntu.com/ubuntu/pool/main/a/alsa-lib/libasound2-data_1.2.11-1ubuntu0.3_all.deb
chrome deb 0ea7acb5e8a8ce4d6653b30e03a319bfe136db7bfb5ee7cad34c2aa1272ea8d9 http://archive.ubuntu.com/ubuntu/pool/main/libx/libxi/libxi6_1.8.1-1build1_amd64.deb
chrome deb 0ee1015cccd063249e01c0cd0bf45f513c8ac9a1e5e485070c12e69192455e4a http://archive.ubuntu.com/ubuntu/pool/main/libx/libxfixes/libxfixes3_6.0.0-2build1_amd64.deb
chrome deb 110a797a57673d3ee497a141cf988199258058c57525799c63194d81822529a0 http://archive.ubuntu.com/ubuntu/pool/main/p/pcre2/libpcre2-8-0_10.42-4ubuntu2.1_amd64.deb
chrome deb 14286795a258593259923619073e50c15345673befae2733f7b0577b07359aa8 http://archive.ubuntu.com/ubuntu/pool/main/libx/libxcb/libxcb-sync1_1.15-1ubuntu2_amd64.deb
chrome deb 148103a436fd273dabfe0fe41dc54873df46227b59b2c7ac7339d7e2ddfd033b http://archive.ubuntu.com/ubuntu/pool/main/l/lm-sensors/libsensors-config_3.6.0-9build1_all.deb
chrome deb 1c0b8daf0130d68de428334ce6d1e11bd11f7369bf9099bbc65ac88117336dc3 http://archive.ubuntu.com/ubuntu/pool/main/m/mesa/libgbm1_25.2.8-0ubuntu0.24.04.2_amd64.deb
chrome deb 22b7d47e3c0f7953a78d3cfd309d1b20771085de9220fbe610c0989b9e808c9b http://archive.ubuntu.com/ubuntu/pool/main/a/at-spi2-core/libatk-bridge2.0-0t64_2.52.0-1build1_amd64.deb
chrome deb 23c627c77c66552a658e62852f244f4946dc543898e0ec5428d5dc6bffde2d6a http://archive.ubuntu.com/ubuntu/pool/main/libc/libcap2/libcap2_2.66-5ubuntu2.4_amd64.deb
chrome deb 2b9caeb423efb540296a1cb20b872cc630c23908407ecb5c1c787a617622d664 http://archive.ubuntu.com/ubuntu/pool/main/libx/libxkbcommon/libxkbcommon0_1.6.0-1build1_amd64.deb
chrome deb 2e36e6557e87dbfd64df3143cbf81a4f75c3447501a545b4730511d228b0dd17 http://archive.ubuntu.com/ubuntu/pool/main/libx/libxcb/libxcb-present0_1.15-1ubuntu2_amd64.deb
chrome deb 319331270d5cc52d5ebffe51c941d7b01b432bc402c2924b557209a64d4ecbad http://archive.ubuntu.com/ubuntu/pool/main/l/lz4/liblz4-1_1.9.4-1build1.1_amd64.deb
chrome deb 397f84347476a3c5786b39f3ff6f0f82866eb3d8be6d2ad3efeadf019efe5b80 http://archive.ubuntu.com/ubuntu/pool/main/libx/libx11/libx11-6_1.8.7-1build1_amd64.deb
chrome deb 3afbc8ddf835049dd4d88275b9d13680e4c4cdd59e191cbd63424152cc08e00e http://archive.ubuntu.com/ubuntu/pool/main/libe/libedit/libedit2_3.1-20230828-1build1_amd64.deb
chrome deb 3bcf169cd65e2539059b2287924090fc629f9bf90f595fc25465a7efe950ee82 http://archive.ubuntu.com/ubuntu/pool/main/u/util-linux/libblkid1_2.39.3-9ubuntu6.6_amd64.deb
chrome deb 3d3d0e95e56ae16010a84883196b8153cba62d6831f9aaee2a68c46f20c7c004 http://archive.ubuntu.com/ubuntu/pool/main/libx/libxcb/libxcb-dri3-0_1.15-1ubuntu2_amd64.deb
chrome deb 4254f11d782dfb970e78113519a59d440112ed43c4b56f709da0aef81da8651a http://archive.ubuntu.com/ubuntu/pool/main/n/nss/libnss3_3.98-1ubuntu0.2_amd64.deb
chrome deb 42c5d4b00954f17c2c3c4b866844f691eb8b6d57bf08b59203e65f12dc84a4f9 http://archive.ubuntu.com/ubuntu/pool/main/a/at-spi2-core/libatk1.0-0t64_2.52.0-1build1_amd64.deb
chrome deb 45783969a9ece9d7b7b733b8c60981584c53c6bc5ee3b42d295d2f80d1285679 http://archive.ubuntu.com/ubuntu/pool/main/libx/libxext/libxext6_1.3.4-1build2_amd64.deb
chrome deb 4776d2ac7e21efe2ae31f3f7955a7ccd97277225eecf36910a26faf4544979ae http://archive.ubuntu.com/ubuntu/pool/main/s/systemd/libsystemd0_255.4-1ubuntu8.17_amd64.deb
chrome deb 494b8e672f722130c6bca6a7bc4cc31a43ca891a31d60d868bfdd699a3c20b13 http://archive.ubuntu.com/ubuntu/pool/main/e/expat/libexpat1_2.6.1-2ubuntu0.6_amd64.deb
chrome deb 4d3e858dd57be617c49d87c5ddcdb35df744a4f0a559981256ae2ba174718584 http://archive.ubuntu.com/ubuntu/pool/main/libd/libdrm/libdrm2_2.4.125-1ubuntu0.1~24.04.2_amd64.deb
chrome deb 515ed1fbe2bc99926c44fe10b1beb9c3510068c344adda334303098d669ba1e5 http://archive.ubuntu.com/ubuntu/pool/main/l/lm-sensors/libsensors5_3.6.0-9build1_amd64.deb
chrome deb 5d17bfb5683eb99f1be951fe48e1be5bf3c52391913b6b74a8aecf9b4f5e779f http://archive.ubuntu.com/ubuntu/pool/main/a/alsa-lib/libasound2t64_1.2.11-1ubuntu0.3_amd64.deb
chrome deb 5d630480f04b4b442300ce847a3fa705ea4d14d80ba6de91f99b51a4e4953b08 http://archive.ubuntu.com/ubuntu/pool/main/d/dbus/libdbus-1-3_1.14.10-4ubuntu4.1_amd64.deb
chrome deb 637e6a7744de08cd331a41f4efd0d24e6ea9064843dea9d1c6ca87bdb5f038a2 http://archive.ubuntu.com/ubuntu/pool/main/libf/libffi/libffi8_3.4.6-1build1_amd64.deb
chrome deb 6891faf325e996ebd28ef53ebb9c043dc96f67327500490affc3e89d366d35ed http://archive.ubuntu.com/ubuntu/pool/main/libx/libxdamage/libxdamage1_1.1.6-1build1_amd64.deb
chrome deb 6abaa6c26f46ef17764c4a753e0e84de1cdadde5634fd2987621fdc617988d19 http://archive.ubuntu.com/ubuntu/pool/main/libs/libselinux/libselinux1_3.5-2ubuntu2.1_amd64.deb
chrome deb 6e578bc383096718c9eea8a76a3edfacfea06e525e1aa7a187ee41906436d94e http://archive.ubuntu.com/ubuntu/pool/main/libx/libxml2/libxml2_2.9.14+dfsg-1.3ubuntu3.9_amd64.deb
chrome deb 6efea3770f738db2fd43ebdaed3d91ef0cde8aa8387b4803080af473326ebdb0 http://archive.ubuntu.com/ubuntu/pool/main/s/systemd/libudev1_255.4-1ubuntu8.17_amd64.deb
chrome deb 7d0d357e47cd6e1042be34da1d37cea313420b000035e71e855087c8268ab127 http://archive.ubuntu.com/ubuntu/pool/main/libx/libx11/libx11-xcb1_1.8.7-1build1_amd64.deb
chrome deb 7e05959b067031468f21ae46c6653a6813f1dccd994ef12a0b5f75de0ed346b6 http://archive.ubuntu.com/ubuntu/pool/main/a/at-spi2-core/at-spi2-common_2.52.0-1build1_all.deb
chrome deb 847195765b9ef7e7886677aeae9987aa54e496758b4e6e5a4ed2cb580b252244 http://archive.ubuntu.com/ubuntu/pool/main/libd/libdrm/libdrm-intel1_2.4.125-1ubuntu0.1~24.04.2_amd64.deb
chrome deb 84b9cf5752b29c9f92c27cd4c4ba9bbcc70b5ccf9b1b515421a28ae23212e273 http://archive.ubuntu.com/ubuntu/pool/main/z/zlib/zlib1g_1.3.dfsg-3.1ubuntu2.2_amd64.deb
chrome deb 87a3b1c2a09f54d229e5e1f5424adc806e8f99bbb8aa8c8dea114b727f7a5a96 http://archive.ubuntu.com/ubuntu/pool/main/libp/libpciaccess/libpciaccess0_0.17-3ubuntu0.24.04.3_amd64.deb
chrome deb 8f2c25589f187dacfdc5bb6be2af0aee6c2ba7b4d2edd1ca4b26753469f07aae http://archive.ubuntu.com/ubuntu/pool/main/u/util-linux/libmount1_2.39.3-9ubuntu6.6_amd64.deb
chrome deb 93654ee8180a73a0363f25c51dc673d67cbabcbecd164187b8a2deb54d007aef http://archive.ubuntu.com/ubuntu/pool/main/libg/libgpg-error/libgpg-error0_1.47-3build2.1_amd64.deb
chrome deb 957b9eeaa83cf6f2d5d5d76dbb8aa31d3297e6781d8a02fa08dcc897ae650a0b http://archive.ubuntu.com/ubuntu/pool/main/libg/libgcrypt20/libgcrypt20_1.10.3-2ubuntu0.2_amd64.deb
chrome deb 9ae01f7747e7f479394c697c55acf11d3baf139e8e54b7c4adfb55ef9c50de08 http://archive.ubuntu.com/ubuntu/pool/main/libx/libx11/libx11-data_1.8.7-1build1_all.deb
chrome deb a12d5d9ae70b798cbbf284080eae32b87367561fc9c24492f641b8860ac0f308 http://archive.ubuntu.com/ubuntu/pool/main/libx/libxcomposite/libxcomposite1_0.4.5-1build3_amd64.deb
chrome deb a51f8de7829211db961a31f02158058ad1a95f92ac6d0a5dff6350e2821c54c0 http://archive.ubuntu.com/ubuntu/pool/main/g/gcc-14/libstdc++6_14.2.0-4ubuntu2~24.04.1_amd64.deb
chrome deb a66ef54888a18e20b55dd3988177f6029caa81dc16198c043a715500b62cf06f http://archive.ubuntu.com/ubuntu/pool/main/g/glib2.0/libglib2.0-0t64_2.80.0-6ubuntu3.9_amd64.deb
chrome deb aa29b7898bae596bf07e55ba178cf8d5ea698fe83688e1b34520d86010251a7a http://archive.ubuntu.com/ubuntu/pool/main/libd/libdrm/libdrm-amdgpu1_2.4.125-1ubuntu0.1~24.04.2_amd64.deb
chrome deb b1190bb72359f5fcc47406aa46065eaf4f1ca208085c51224a52b04bedc0b4bb http://archive.ubuntu.com/ubuntu/pool/main/s/sqlite3/libsqlite3-0_3.45.1-1ubuntu2.8_amd64.deb
chrome deb b4aee123a37472d213647594b4f7d4a0d13615b0ca2a6fd33926b768d6b232c2 http://archive.ubuntu.com/ubuntu/pool/main/e/elfutils/libelf1t64_0.190-1.1ubuntu0.1_amd64.deb
chrome deb b5cb519823a05a617b543dc9b6a9289b7648b20048244abe021caa706309835a http://archive.ubuntu.com/ubuntu/pool/main/libx/libxcb/libxcb-randr0_1.15-1ubuntu2_amd64.deb
chrome deb b67a6df2bdab61d273eabebd208bb6a3fb12618a390a067e1ee305a409ff03d9 http://archive.ubuntu.com/ubuntu/pool/main/n/ncurses/libtinfo6_6.4+20240113-1ubuntu2.2_amd64.deb
chrome deb b95c172411a7fdae70307cf33a9f5320ba5e056b556454543dd5b679d5ce1c4f http://archive.ubuntu.com/ubuntu/pool/main/g/gcc-14/gcc-14-base_14.2.0-4ubuntu2~24.04.1_amd64.deb
chrome deb bc6de4bfaf9050a8ba83d4bcfb114131b081084a7972c03417f8523d52b5c742 http://archive.ubuntu.com/ubuntu/pool/main/libx/libxshmfence/libxshmfence1_1.3-1build5_amd64.deb
chrome deb bcd336fce11ce2a45f34d0f95e6980af22529f22147e8f98c156e5cee8ee42bb http://archive.ubuntu.com/ubuntu/pool/main/libx/libxdmcp/libxdmcp6_1.1.3-0ubuntu6_amd64.deb
chrome deb c9a70989678660eed9a1e904c74fa043da8bec8e2036856fc16e31ced79b04f8 http://archive.ubuntu.com/ubuntu/pool/main/i/icu/libicu74_74.2-1ubuntu3.1_amd64.deb
chrome deb d2eabd41ca77d2c2dd9d5d4ef478cccb64ffde6279c47cf4699a857d46785a52 http://archive.ubuntu.com/ubuntu/pool/main/x/xz-utils/liblzma5_5.6.1+really5.4.5-1ubuntu0.3_amd64.deb
chrome deb d686ace4080eca9c2d6ce8de69392a5ac56c846701894c0858922d4ce341a1d7 http://archive.ubuntu.com/ubuntu/pool/main/a/at-spi2-core/libatspi2.0-0t64_2.52.0-1build1_amd64.deb
chrome deb d70bd831aebe8d4834b5dd2ed98df26dd6bd27f1042c47543bd7f66df1ae22ea http://archive.ubuntu.com/ubuntu/pool/main/libx/libxrender/libxrender1_0.9.10-1.1build1_amd64.deb
chrome deb dfcf25061e07aad7efd3f4f880ba5ad4d4d09ebe7fc8cc77ab6b8a161d6d4727 http://archive.ubuntu.com/ubuntu/pool/main/libz/libzstd/libzstd1_1.5.5+dfsg2-2build1.1_amd64.deb
chrome deb e1c6611d11ad7398326f1bf028afc34c3b14c51d917a3426b966ed4b9687fa58 http://archive.ubuntu.com/ubuntu/pool/main/libx/libxcb/libxcb1_1.15-1ubuntu2_amd64.deb
chrome deb e40d29f1d1a62393bacaedebe0da3d9006084152a9f7e5e029293f08ce1c5c80 http://archive.ubuntu.com/ubuntu/pool/main/libx/libxau/libxau6_1.0.9-1build6_amd64.deb
chrome deb e46e42e305339765f51f994543cef2a8bf4a7d9ab7004161db1a6d1f291694de http://archive.ubuntu.com/ubuntu/pool/main/m/mesa/mesa-libgallium_25.2.8-0ubuntu0.24.04.2_amd64.deb
chrome deb e579e72d091f6c7a13f5a756c31065b15aae5b81840d61b069355aa2283c07b4 http://archive.ubuntu.com/ubuntu/pool/main/n/nspr/libnspr4_4.35-1.1build1_amd64.deb
chrome deb e5ba01d3c41f256aaf57ec59aa0554857162e3e7f97cdfbff1ed2c0e8d720ee7 http://archive.ubuntu.com/ubuntu/pool/main/libm/libmd/libmd0_1.1.0-2build1.1_amd64.deb
chrome deb e99f2a0b4c56cdf35dec489e56b6a8418826cab8ce6306ec6d0bd98e2cd0014a http://archive.ubuntu.com/ubuntu/pool/main/x/xkeyboard-config/xkb-data_2.41-2ubuntu1.1_all.deb
chrome deb f018e71c72c7a4742fb1aff9dc98b45586f42e6ea464d4918af7e3772b7f0658 http://archive.ubuntu.com/ubuntu/pool/main/l/llvm-toolchain-20/libllvm20_20.1.2-0ubuntu1~24.04.3_amd64.deb
chrome deb f2955a5e594f5724b58ad241d9231ea191cb36574a0d5e5ca6b661cd41d6256d http://archive.ubuntu.com/ubuntu/pool/main/libx/libxrandr/libxrandr2_1.5.2-2build1_amd64.deb
chrome deb f3857b0863ac5cfd4263e9bf6cfb1d4be88d5321e4070d5bc2b62b0949e6c86f http://archive.ubuntu.com/ubuntu/pool/main/libb/libbsd/libbsd0_0.12.1-1build1.1_amd64.deb
chrome zip 5a6979d0ab7cf952ea575d35164e7bdce4872b2ced8f8a215c8f8e8eda00ee09 https://storage.googleapis.com/chrome-for-testing-public/154.0.8037.57/linux64/chrome-headless-shell-linux64.zip
lsof deb 0679f198b0128179e46cdf956fb2022c23c758664c00bc8efa0382d509683a8a http://archive.ubuntu.com/ubuntu/pool/main/k/keyutils/libkeyutils1_1.6.3-3build1_amd64.deb
lsof deb 0d4a0187bcdbbe3e6a10bfa574100087d12052d0d0ef28614fd6210021c587b2 http://archive.ubuntu.com/ubuntu/pool/main/k/krb5/libgssapi-krb5-2_1.20.1-6ubuntu2.10_amd64.deb
lsof deb 110a797a57673d3ee497a141cf988199258058c57525799c63194d81822529a0 http://archive.ubuntu.com/ubuntu/pool/main/p/pcre2/libpcre2-8-0_10.42-4ubuntu2.1_amd64.deb
lsof deb 212d8873ac952bc68f4cf56d7eaf17566f86f5c7cc4b971899a0c56e174699cc http://archive.ubuntu.com/ubuntu/pool/main/libt/libtirpc/libtirpc-common_1.3.4+ds-1.1build1_all.deb
lsof deb 273f7cc95a68d927d7f71c3e78b7717a16a8d86e646a206bae7bf797150ae9db http://archive.ubuntu.com/ubuntu/pool/main/k/krb5/libk5crypto3_1.20.1-6ubuntu2.10_amd64.deb
lsof deb 3a3cd37160399ab235fdf2f13159fd288940abb9660e0ed1afb418b44c73d43a http://archive.ubuntu.com/ubuntu/pool/main/libt/libtirpc/libtirpc3t64_1.3.4+ds-1.1build1_amd64.deb
lsof deb 219f43b1cd836a4da550938db5fda93160d269d39a4edcf1f1ce698a470db797 http://archive.ubuntu.com/ubuntu/pool/main/o/openssl/libssl3t64_3.0.13-0ubuntu3.16_amd64.deb
lsof deb 46165f06b9568f9e2718f1fdd3d3a8db46aa597f5ff163c1d21c0d1daa12191d http://archive.ubuntu.com/ubuntu/pool/main/l/lsof/lsof_4.95.0-1build3_amd64.deb
lsof deb 60b48c5a3233f1d8caba30d6573edc8e131911ab6d63adcd664f7cbe62708362 http://archive.ubuntu.com/ubuntu/pool/main/k/krb5/libkrb5-3_1.20.1-6ubuntu2.10_amd64.deb
lsof deb 6abaa6c26f46ef17764c4a753e0e84de1cdadde5634fd2987621fdc617988d19 http://archive.ubuntu.com/ubuntu/pool/main/libs/libselinux/libselinux1_3.5-2ubuntu2.1_amd64.deb
lsof deb 7ab24d3057dabf86db8f771ad6e43f073ed86b6b950d6e8ba22cb9fe6707bbc9 http://archive.ubuntu.com/ubuntu/pool/main/e/e2fsprogs/libcom-err2_1.47.0-2.4~exp1ubuntu4.1_amd64.deb
lsof deb 9224ede3246a82a845ea97652ecfae57f88e8d8f520d8a186f9157167574fb34 http://archive.ubuntu.com/ubuntu/pool/main/k/krb5/libkrb5support0_1.20.1-6ubuntu2.10_amd64.deb
ps deb 08d7baeff0285804178a8ed99b49514f210d38881bd118157cd9e222646c17a5 http://archive.ubuntu.com/ubuntu/pool/main/p/procps/procps_4.0.4-4ubuntu3.3_amd64.deb
ps deb 23c627c77c66552a658e62852f244f4946dc543898e0ec5428d5dc6bffde2d6a http://archive.ubuntu.com/ubuntu/pool/main/libc/libcap2/libcap2_2.66-5ubuntu2.4_amd64.deb
ps deb 319331270d5cc52d5ebffe51c941d7b01b432bc402c2924b557209a64d4ecbad http://archive.ubuntu.com/ubuntu/pool/main/l/lz4/liblz4-1_1.9.4-1build1.1_amd64.deb
ps deb 4776d2ac7e21efe2ae31f3f7955a7ccd97277225eecf36910a26faf4544979ae http://archive.ubuntu.com/ubuntu/pool/main/s/systemd/libsystemd0_255.4-1ubuntu8.17_amd64.deb
ps deb 579c9488755d1ddd70f66480cafd2f68776f68314d15d9cf4b5449d0de0fc968 http://archive.ubuntu.com/ubuntu/pool/main/n/ncurses/libncursesw6_6.4+20240113-1ubuntu2.2_amd64.deb
ps deb 8a73e2656ddcdb078e06e20abb5a92b182145e12376a9a9282db8374da34d228 http://archive.ubuntu.com/ubuntu/pool/main/p/procps/libproc2-0_4.0.4-4ubuntu3.3_amd64.deb
ps deb 93654ee8180a73a0363f25c51dc673d67cbabcbecd164187b8a2deb54d007aef http://archive.ubuntu.com/ubuntu/pool/main/libg/libgpg-error/libgpg-error0_1.47-3build2.1_amd64.deb
ps deb 957b9eeaa83cf6f2d5d5d76dbb8aa31d3297e6781d8a02fa08dcc897ae650a0b http://archive.ubuntu.com/ubuntu/pool/main/libg/libgcrypt20/libgcrypt20_1.10.3-2ubuntu0.2_amd64.deb
ps deb b67a6df2bdab61d273eabebd208bb6a3fb12618a390a067e1ee305a409ff03d9 http://archive.ubuntu.com/ubuntu/pool/main/n/ncurses/libtinfo6_6.4+20240113-1ubuntu2.2_amd64.deb
ps deb d2eabd41ca77d2c2dd9d5d4ef478cccb64ffde6279c47cf4699a857d46785a52 http://archive.ubuntu.com/ubuntu/pool/main/x/xz-utils/liblzma5_5.6.1+really5.4.5-1ubuntu0.3_amd64.deb
ps deb dfcf25061e07aad7efd3f4f880ba5ad4d4d09ebe7fc8cc77ab6b8a161d6d4727 http://archive.ubuntu.com/ubuntu/pool/main/libz/libzstd/libzstd1_1.5.5+dfsg2-2build1.1_amd64.deb
ruby deb 285f8a505dfa8e1b33f357a9d8d3477ad35bf18c0b34771a6df4c25923f3ae0d http://archive.ubuntu.com/ubuntu/pool/main/g/gmp/libgmp10_6.3.0+dfsg-2ubuntu6.1_amd64.deb
ruby deb 84b9cf5752b29c9f92c27cd4c4ba9bbcc70b5ccf9b1b515421a28ae23212e273 http://archive.ubuntu.com/ubuntu/pool/main/z/zlib/zlib1g_1.3.dfsg-3.1ubuntu2.2_amd64.deb
ruby deb 9474785cd6f398512bf8c305c3901dbb111569dccb6f5832002373c0a8ac5832 http://archive.ubuntu.com/ubuntu/pool/main/libx/libxcrypt/libcrypt1_4.4.36-4build1_amd64.deb
ruby deb f5271b120d936dcc7ddf17b9e718df41d55386a6075555d0c634925eaef0b2ac http://archive.ubuntu.com/ubuntu/pool/main/liby/libyaml/libyaml-0-2_0.2.5-1build1_amd64.deb
ruby tar e3d114c546332243f84755aa277ba1e1781deba686050d729d2806d3766baf25 https://github.com/ruby/ruby-builder/releases/download/ruby-3.4.11/ruby-3.4.11-ubuntu-24.04-x64.tar.gz
PINS

LIBPATH="$DESTINATION/payload/usr/lib/x86_64-linux-gnu"
if [ -d "$DESTINATION/payload/ruby/x64/lib" ]; then
  LIBPATH="$LIBPATH:$DESTINATION/payload/ruby/x64/lib"
fi

write_wrapper() {
  name=$1
  real=$2
  extra=$3
  cat > "$DESTINATION/bin/$name" <<EOF
#!/bin/sh
export LD_LIBRARY_PATH='$LIBPATH'\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
$extra
exec '$real' "\$@"
EOF
  chmod +x "$DESTINATION/bin/$name"
}

if tool_selected ruby; then
  ruby_bin="$DESTINATION/payload/ruby/x64/bin/ruby"
  ruby_lib="$DESTINATION/payload/ruby/x64/lib/ruby/3.4.0"
  [ -x "$ruby_bin" ] || die "ruby binary missing after extract"
  [ -d "$ruby_lib/x86_64-linux" ] || die "ruby stdlib missing after extract"
  write_wrapper ruby "$ruby_bin" "export RUBYLIB='$ruby_lib:$ruby_lib/x86_64-linux'"
  "$DESTINATION/bin/ruby" -ryaml -e 'doc = YAML.load("---\nk: 1\n"); abort("yaml") unless doc["k"] == 1'
fi

if tool_selected ps; then
  ps_bin="$DESTINATION/payload/usr/bin/ps"
  [ -x "$ps_bin" ] || die "ps binary missing after extract"
  write_wrapper ps "$ps_bin" ""
  pgid=$("$DESTINATION/bin/ps" -o pgid= -p $$ | tr -d '[:space:]')
  case "$pgid" in
    ''|*[!0-9]*) die "ps -o pgid= did not return a process group" ;;
  esac
fi

if tool_selected lsof; then
  lsof_bin="$DESTINATION/payload/usr/bin/lsof"
  [ -x "$lsof_bin" ] || die "lsof binary missing after extract"
  write_wrapper lsof "$lsof_bin" ""
  "$DESTINATION/bin/lsof" -a -d cwd -p $$ -Fpn >/dev/null
fi

if tool_selected chrome; then
  chrome_bin="$DESTINATION/payload/chrome-headless-shell-linux64/chrome-headless-shell"
  [ -x "$chrome_bin" ] || die "chrome-headless-shell missing after extract"
  xkb="$DESTINATION/payload/usr/share/X11/xkb"
  write_wrapper google-chrome "$chrome_bin" "export XKB_CONFIG_ROOT='$xkb'"
  html="$TMP/page.html"
  printf '<html><body>ok</body></html>\n' > "$html"
  "$DESTINATION/bin/google-chrome" \
    --headless=new \
    --disable-gpu \
    --no-sandbox \
    --disable-dev-shm-usage \
    --disable-background-networking \
    --virtual-time-budget=2000 \
    --dump-dom \
    "file://$html" > "$TMP/dom.html"
  grep -Fq '</html>' "$TMP/dom.html" || die "chrome dump-dom did not render"
fi

printf 'fm-install-runner-tools.sh: installed into %s\n' "$DESTINATION/bin" >&2
