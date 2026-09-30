#!/bin/bash
# Check and load environment variables from .env
if [ -f .env ]; then
    export $(cat .env | grep -v '#' | xargs)
    echo "✓ Loaded .env from current directory"
elif [ -f ../.env ]; then
    export $(cat ../.env | grep -v '#' | xargs)
    echo "✓ Loaded .env from parent directory"
else
    echo "⚠ .env file not found"
fi

# Configure git to authenticate against github.com via a request header
# instead of embedding the token in the URL. URL-embedded tokens get stripped
# by git on GitHub's redirect (https://github.com/... → https://github.com/.../),
# which is why we were getting "Username for 'https://github.com':" prompts.
# The header survives redirects and applies to every git/repo operation.
setup_git_auth() {
    [ -z "${GH_TOKEN:-}" ] && return
    git config --global --unset-all url."https://github.com/".insteadOf 2>/dev/null || true
    git config --global --unset-all url."https://${GH_TOKEN}@github.com/".insteadOf 2>/dev/null || true
    git config --global --unset-all http.https://github.com/.extraHeader 2>/dev/null || true
    git config --global http.https://github.com/.extraHeader \
        "Authorization: Basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64)"
}
setup_git_auth

if ls out/target/product/*/*.zip >/dev/null 2>&1; then

rm -rf testonly
git clone https://github.com/xc112lg/testonly

#cd -
#rm -rf blossom_lunaris/*.img blossom_lunaris/*.zip blossom_lunaris/*.tar
#cp out/target/product/*/recovery.img blossom_lunaris
rm out/target/product/*/*-ota.zip
cp out/target/product/*/*.zip testonly/
for img in out/target/product/*/recovery.img; do
    device=$(basename "$(dirname "$img")")
    cp "$img" "testonly/${device}_recovery.img"
done

for img in out/target/product/*/boot.img; do
    device=$(basename "$(dirname "$img")")
    cp "$img" "testonly/${device}_boot.img"
done
# echo "test" > blossom_lunaris/dummy.txt

# Create the zip
# zip -q blossom_lunaris/test.zip blossom_lunaris/dummy.txt

# Check size
# ls -lh blossom_lunaris/test.zip
cd testonly
chmod +x multi_upload3.sh
./multi_upload3.sh > /dev/null
else
    exit 1
fi
