#!/bin/bash

# Set proper UTF-8 encoding for special characters
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

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

if ! command -v gh &> /dev/null; then
    echo "GitHub CLI 'gh' not found. Downloading and installing..."
    wget https://github.com/cli/cli/releases/download/v2.40.1/gh_2.40.1_linux_amd64.tar.gz
    tar -xvf gh_2.40.1_linux_amd64.tar.gz
    sudo mv gh_*_linux_amd64/bin/gh /usr/local/bin/
    echo "GitHub CLI 'gh' installed successfully."
else
    echo "GitHub CLI 'gh' is already installed."
fi

if ! gh auth status &> /dev/null; then
    gh auth login --with-token $GH_TOKEN
else
    echo "Already authenticated with GitHub."
fi

version=${custom_version:-"EvolutionX-16.0-$(date '+%Y%m%d')"}

if gh release view "$version" &> /dev/null; then
    echo "Deleting existing tag and releases for $version..."
    gh release delete "$version" --yes
    git tag -d "$version"
    git push origin --delete "$version"
    echo "Existing tag and releases deleted."
fi

git tag -a "$version" -m "Release $version"
git push origin "$version" --force

declare -a filenames
filenames=(*.zip *.img *.txt *.json)

if ! gh release create "$version" --title "Release $version" --notes "Release notes"; then
    echo "Error: Failed to create the release."
    exit 1
fi

for filename in "${filenames[@]}"; do
    gh release upload "$version" "$filename" --clobber
done

echo "Files uploaded successfully."

# ============================================
# TELEGRAM NOTIFICATION
# ============================================

echo "Preparing to send Telegram notification..."

RELEASE_TAG="$version"
GITHUB_REPO="${GITHUB_REPO:-testonly}"
declare -a FILE_ENTRIES

for filename in "${filenames[@]}"; do
    if [ -f "$filename" ]; then
        download_url="https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases/download/$RELEASE_TAG/$filename"
        file_size=$(du -h "$filename" 2>/dev/null | cut -f1)
        
        FILE_ENTRIES+=("${filename}|${download_url}|${file_size}")
    fi
done

CHANGELOG_URL="https://t.me/ProjectInfinityX/1882"

if [ -n "$TELEGRAPH_TOKEN" ]; then
    CHANGELOG_CONTENT=$(curl -fsSL \
        "https://raw.githubusercontent.com/Evolution-X/changelog/refs/heads/bka/changelogs/LATEST.txt" 2>/dev/null)

    if [ -n "$CHANGELOG_CONTENT" ]; then

        TELEGRAPH_RESPONSE=$(curl -s \
            -X POST "https://api.telegra.ph/createPage" \
            -d "access_token=$TELEGRAPH_TOKEN" \
            --data-urlencode "title=Evolution-X Changelog $(date '+%Y-%m-%d')" \
            --data-urlencode "author_name=xc112lg" \
            --data-urlencode "content=[{\"tag\":\"pre\",\"children\":[$(jq -Rs . <<< "$CHANGELOG_CONTENT")]}]")

        CHANGELOG_URL=$(echo "$TELEGRAPH_RESPONSE" | jq -r '.result.url // empty')

        if [ -n "$CHANGELOG_URL" ]; then
            echo "✓ Changelog uploaded: $CHANGELOG_URL"
        else
            CHANGELOG_URL="https://t.me/ProjectInfinityX/1882"
            echo "⚠ Failed to create Telegraph page"
        fi
    fi
fi

# Create Downloads section with LABELS ONLY (no filename shown)
DOWNLOADS_SECTION="
<b>📥 Downloads:</b>"

for file_entry in "${FILE_ENTRIES[@]}"; do
    filename="${file_entry%%|*}"
    remaining="${file_entry#*|}"
    url="${remaining%%|*}"
    size="${remaining##*|}"
    
    # Known device codenames to detect in the filename (add more as needed)
    known_devices=("h870" "h871" "h872" "h873" "h930" "us997" "ls993" "vs988" "as993")
    device_code=""
    filename_lower=$(echo "$filename" | tr '[:upper:]' '[:lower:]')
    for dev in "${known_devices[@]}"; do
        if [[ "$filename_lower" == *"$dev"* ]]; then
            device_code="$dev"
            break
        fi
    done

    # Create label based on filename but don't show actual filename
    label="File"
    download_links=""

    if [[ "$filename" == *"Vanilla"* ]] || [[ "$filename" == *"vanilla"* ]]; then
        if [ -n "$device_code" ]; then
            label="📱 ${device_code} Vanilla ROM"
        else
            label="📱 Vanilla ROM"
        fi
        download_links="<a href=\"${url}\">GitHub</a>"
    elif [[ "$filename" == *"GApps"* ]] || [[ "$filename" == *"gapps"* ]]; then
        label="🎯 GApps Package"
        download_links="<a href=\"${url}\">GitHub</a> | <a href=\"https://sourceforge.net/projects/nikgapps/files/Releases/Android-16/\">SourceForge</a>"
    elif [[ "$filename" == *"recovery"* ]] || [[ "$filename" == *"Recovery"* ]]; then
        if [ -n "$device_code" ]; then
            label="🔧 ${device_code} Recovery Image"
        else
            label="🔧 Recovery Image"
        fi
        download_links="<a href=\"${url}\">Download</a>"
    elif [[ "$filename" == *.zip ]]; then
        if [ -n "$device_code" ]; then
            label="📦 ${device_code} ROM Package"
        else
            label="📦 ROM Package"
        fi
        download_links="<a href=\"${url}\">Download</a>"
    elif [[ "$filename" == *.img ]]; then
        if [ -n "$device_code" ]; then
            label="💾 ${device_code} Image File"
        else
            label="💾 Image File"
        fi
        download_links="<a href=\"${url}\">Download</a>"
    fi

    # Only show label and links, NO original full filename anywhere
    DOWNLOADS_SECTION+="
🔹 ${label} - ${download_links} (${size})"

done

# GApps line shown once, not repeated per entry
DOWNLOADS_SECTION+="
🔹 🎯 GApps Package <a href=\"https://sourceforge.net/projects/nikgapps/files/Releases/Android-15/\">SourceForge</a>"

# Create full Telegram message
TELEGRAM_MESSAGE="<b>EvolutionX-15.0 | UNOFFICIAL📱</b>

<b>Device:</b>Blossom
<b>👨‍💻 Builder:</b> <a href=\"http://t.me/xc112lg\">xc112lg</a>
<b>🤖 Android Version:</b> 15
<b>📅 Build Date:</b> $(date '+%d/%m/%y')
<b>⚙️ <a href=\"$CHANGELOG_URL\">Changelog</a></b>

$DOWNLOADS_SECTION

<b>📝 Notes:</b>
• Work with both core and basic gapps
• Signed
• July security patch
• Default Kernel Swan

<b>❤️ Credits & Thanks:</b>
• npjohnson
• lineageOS dev team
• ROMSG for kernel
• Thanks to <a href=\"http://foss.crave.io\">crave.io</a> for server
• Thanks to all other devs

<b>🌐 Stay Updated:</b>
📢 @LGG6_group
📢 @LGG6_releases

#LGG^ #UNOFFICIAL #Evolution-X #lunaridolby #Rom"

# Send Telegram message with smart fallback
if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    echo "⚠ Telegram credentials not set. Skipping Telegram notification."
else
    echo "Sending Telegram notification..."

    # Banner image URL
    BANNER_IMAGE="https://github.com/Evolution-X/manifest/raw/bka/Banner.png"

    # Check message length
    MSG_LENGTH=${#TELEGRAM_MESSAGE}
    echo "Message length: $MSG_LENGTH characters"
    
    # Telegram caption limit (conservative estimate)
    CAPTION_LIMIT=3500

    if [ $MSG_LENGTH -le $CAPTION_LIMIT ]; then
        # Message fits in caption - send as merged
        echo "✓ Message fits in caption - sending merged (image + text in one)"
        
        TEMP_JSON=$(mktemp)
        cat > "$TEMP_JSON" << JSONEOF
{
    "chat_id": $TELEGRAM_CHAT_ID,
    "photo": "$BANNER_IMAGE",
    "caption": $(printf '%s\n' "$TELEGRAM_MESSAGE" | jq -R -s .),
    "parse_mode": "HTML"
}
JSONEOF

        RESPONSE=$(curl -s -X POST \
            -H "Content-Type: application/json" \
            -d @"$TEMP_JSON" \
            "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendPhoto")

        rm -f "$TEMP_JSON"

        if echo "$RESPONSE" | grep -q '"ok":true'; then
            echo "✓ Telegram notification sent successfully (merged)!"
        else
            echo "⚠ Merged send failed, trying fallback..."
            FALLBACK=1
        fi
    else
        # Message too long for caption - use fallback
        echo "⚠ Message too long for caption ($MSG_LENGTH > $CAPTION_LIMIT)"
        echo "✓ Using fallback: Sending image + text as separate messages"
        FALLBACK=1
    fi

    # FALLBACK: Send image and text separately if needed
    if [ "$FALLBACK" == "1" ]; then
        echo "Sending image first..."
        
        # Send image
        curl -s -X POST \
            -H "Content-Type: application/json" \
            -d "{\"chat_id\": $TELEGRAM_CHAT_ID, \"photo\": \"$BANNER_IMAGE\", \"caption\": \"<b>ProjectInfinity-X 3.11 Release</b>\", \"parse_mode\": \"HTML\"}" \
            "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendPhoto" > /dev/null

        echo "Sending full message..."
        
        # Send full text message
        TEMP_JSON=$(mktemp)
        cat > "$TEMP_JSON" << JSONEOF
{
    "chat_id": $TELEGRAM_CHAT_ID,
    "text": $(printf '%s\n' "$TELEGRAM_MESSAGE" | jq -R -s .),
    "parse_mode": "HTML"
}
JSONEOF

        RESPONSE=$(curl -s -X POST \
            -H "Content-Type: application/json" \
            -d @"$TEMP_JSON" \
            "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage")

        rm -f "$TEMP_JSON"

        if echo "$RESPONSE" | grep -q '"ok":true'; then
            echo "✓ Telegram notification sent successfully (fallback)!"
        else
            echo "✗ Failed to send Telegram notification"
            echo "Response: $RESPONSE"
        fi
    fi
fi

echo "✓ Release complete!"
