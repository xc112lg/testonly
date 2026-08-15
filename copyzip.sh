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


rm -rf testonly
git clone https://$GH_TOKEN@github.com/xc112lg/testonly

#cd -
#rm -rf blossom_lunaris/*.img blossom_lunaris/*.zip blossom_lunaris/*.tar
#cp out/target/product/*/recovery.img blossom_lunaris
rm out/target/product/*/*-ota.zip
cp final_images/*.zip testonly/

# echo "test" > blossom_lunaris/dummy.txt

# Create the zip
# zip -q blossom_lunaris/test.zip blossom_lunaris/dummy.txt

# Check size
# ls -lh blossom_lunaris/test.zip
cd testonly
chmod +x multi_upload3.sh
./multi_upload3.sh > /dev/null
