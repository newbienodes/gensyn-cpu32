#!/bin/bash

# Pastikan script akan keluar jika ada perintah yang gagal atau variabel yang belum diatur.
# Kecualikan error dari pipe di bagian `if` utama untuk peluncuran Gensyn.
# Ini adalah metode paling robust untuk memastikan script utama tidak crash prematur.
set -euo pipefail

# --- Konfigurasi Awal ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR"

GENRL_TAG="v0.1.1"

export IDENTITY_PATH
export GENSYN_RESET_CONFIG
export CONNECT_TO_TESTNET=true
export ORG_ID
export HF_HUB_DOWNLOAD_TIMEOUT=120
export SWARM_CONTRACT="0xFaD7C5e93f28257429569B854151A1B8DCD404c2"

# --- Konfigurasi Otomatisasi Prompt ---
SOURCE_EZLABS_DIR="/root/ezlabs/"
DEST_MODAL_DATA_DIR="$ROOT/modal-login/temp-data/"
DEST_ROOT_DIR="$ROOT/"

export HUGGINGFACE_ACCESS_TOKEN="None"
AUTO_MODEL_NAME="Gensyn/Qwen2.5-0.5B-Instruct"
AUTO_LOGIN_STATUS="n"
# --- Akhir Konfigurasi Otomatisasi Prompt ---

DEFAULT_IDENTITY_PATH="$ROOT"/swarm.pem
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}

DOCKER=${DOCKER:-""}
GENSYN_RESET_CONFIG=${GENSYN_RESET_CONFIG:-""}

if [ -n "$DOCKER" ]; then
    volumes=(
        /home/gensyn/rl_swarm/modal-login/temp-data
        /home/gensyn/rl_swarm/keys
        /home/gensyn/rl_swarm/configs
        /home/gensyn/rl_swarm/logs
    )
    for volume in "${volumes[@]}"; do
        sudo chown -R 1001:1001 "$volume"
    done
fi

CPU_ONLY=${CPU_ONLY:-""}
ORG_ID=${ORG_ID:-""}

GREEN_TEXT="\033[32m"
BLUE_TEXT="\033[34m"
RED_TEXT="\033[31m"
RESET_TEXT="\033[0m"

echo_green() {
    echo -e "$GREEN_TEXT$1$RESET_TEXT"
}
echo_blue() {
    echo -e "$BLUE_TEXT$1$RESET_TEXT"
}
echo_red() {
    echo -e "$RED_TEXT$1$RESET_TEXT"
}

# --- Fungsi Cleanup Saat Keluar ---
SERVER_PID=""
GENSYN_RUNNER_PID="" # Ini akan jadi PID dari proses tee, yang juga menjaga pipe tetap hidup
PYTHON_ACTUAL_PID="" # PID dari proses Python yang sebenarnya
TEE_PID="" # PID eksplisit untuk proses tee

cleanup() {
    echo_green ">> Mematikan trainer..."
    cd "$ROOT" || true

    if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        echo ">> Menghentikan server modal-login (PID: $SERVER_PID)..."
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi

    # Kill proses Python Gensyn yang sebenarnya dulu
    if [ -n "${PYTHON_ACTUAL_PID:-}" ] && kill -0 "$PYTHON_ACTUAL_PID" 2>/dev/null; then
        echo ">> Menghentikan proses Python Gensyn (PID: $PYTHON_ACTUAL_PID)..."
        kill "$PYTHON_ACTUAL_PID" 2>/dev/null || true
        wait "$PYTHON_ACTUAL_PID" 2>/dev/null || true
    fi

    # Pastikan proses tee juga dihentikan, ini penting untuk pipe
    if [ -n "${TEE_PID:-}" ] && kill -0 "$TEE_PID" 2>/dev/null; then
        echo ">> Menghentikan proses tee (PID: $TEE_PID)..."
        kill "$TEE_PID" 2>/dev/null || true
        wait "$TEE_PID" 2>/dev/null || true
    fi

    rm -r "$ROOT"/modal-login/temp-data/*.json 2> /dev/null || true

    echo_green ">> Trainer berhasil dimatikan."
    # JANGAN panggil exit 0 di sini. Biarkan trap EXIT utama yang mengontrol.
}

# --- Fungsi Pemberitahuan Error Skrip Bash (di luar loop utama) ---
errnotify() {
    echo_red ">> TERDETEKSI ERROR KRITIS PADA SKRIP BASH. Proses dihentikan. Lihat $ROOT/logs/swarm_launcher.log untuk log lengkap."
    trap - ERR
    cleanup # Lakukan cleanup
    exit 1 # Keluar dari skrip Bash
}

trap errnotify ERR # Atur trap ERR di awal untuk menangkap error Bash di luar loop

echo -e "\033[38;5;224m"
cat << "EOF"
    ██████  ██          ███████ ██      ██  █████  ██████  ███    ███
    ██  ██ ██          ██      ██      ██ ██  ██ ██  ██ ████  ████
    ██████  ██      █████ ███████ ██  █  ██ ███████ ██████  ██ ████ ██
    ██  ██ ██          ██ ██ ███ ██ ██  ██ ██  ██ ██  ██ ██  ██  ██
    ██  ██ ███████      ███████  ███ ███  ██  ██ ██  ██ ██    ██

    From Gensyn

EOF

mkdir -p "$ROOT/logs"

install_localtunnel() {
    if command -v lt >/dev/null 2>&1; then
        echo_green ">> Localtunnel sudah terinstal."
        return 0
    fi
    echo_green ">> Menginstal localtunnel..."
    npm install -g localtunnel > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo_green ">> Localtunnel berhasil diinstal."
        return 0
    else
        echo_red ">> Gagal menginstal localtunnel."
        return 1
    fi
}

start_localtunnel() {
    PORT=3000
    echo_green ">> Memulai localtunnel di port $PORT..."
    lt --port "$PORT" > localtunnel_output.log 2>&1 &
    TUNNEL_PID=$!
    
    sleep 5
    URL=$(grep -o "https://[^ ]*" localtunnel_output.log | head -n1)
    
    if [ -n "$URL" ]; then
        PASS=$(curl -s https://loca.lt/mytunnelpassword)
        echo_green ">> Berhasil! Silakan kunjungi website ini: ${URL}"
        echo_green ">> Kemudian masukkan password ini: ${PASS} untuk mengakses website dan login menggunakan email Anda."
        return 0
    else
        echo_red ">> Gagal mendapatkan URL localtunnel."
        kill "$TUNNEL_PID" 2>/dev/null || true
        return 1
    fi
}

if [ "$CONNECT_TO_TESTNET" = true ]; then
    echo "Harap login untuk membuat Ethereum Server Wallet"

    cd "$ROOT/modal-login"
    
    if ! command -v node > /dev/null 2>&1; then
        echo "Node.js tidak ditemukan. Menginstal NVM dan Node.js terbaru..."
        export NVM_DIR="$HOME/.nvm"
        if [ ! -d "$NVM_DIR" ]; then
            curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
        fi
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
        nvm install node
    else
        echo "Node.js sudah terinstal: $(node -v)"
    fi

    if ! command -v yarn > /dev/null 2>&1; then
        if grep -qi "ubuntu" /etc/os-release 2> /dev/null || uname -r | grep -qi "microsoft"; then
            echo "Terdeteksi Ubuntu atau WSL Ubuntu. Menginstal Yarn via apt..."
            curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
            echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
            sudo apt update && sudo apt install -y yarn
        else
            echo "Yarn tidak ditemukan. Menginstal Yarn secara global dengan npm..."
            npm install -g --silent yarn
        fi
    fi

    ENV_FILE="$ROOT"/modal-login/.env
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "3s/.*/SMART_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
    else
        sed -i "3s/.*/SMART_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
    fi

    if [ -z "$DOCKER" ]; then
        yarn install --immutable
        echo "Membangun server"
        yarn build > "$ROOT/logs/yarn.log" 2>&1
    fi
    yarn start >> "$ROOT/logs/yarn.log" 2>&1 & # Run in background and log output
    SERVER_PID=$!
    echo "Proses server dimulai: $SERVER_PID"
    sleep 5

    echo_green "Harap login untuk melanjutkan, Anda tidak perlu login jika sudah login [y/n]"
    login_status="$AUTO_LOGIN_STATUS"

    case "$login_status" in
        y|Y)
            echo_green ">> Melanjutkan dengan proses login..."
            rm -r "$ROOT/modal-login/temp-data/*.json" 2> /dev/null || true

            if [ -z "$DOCKER" ]; then
                if ! install_localtunnel || ! start_localtunnel; then
                    if open http://localhost:3000 2> /dev/null; then
                        echo_green ">> Berhasil membuka http://localhost:3000 di browser default Anda."
                    else
                        echo ">> Gagal membuka http://localhost:3000. Harap buka secara manual."
                    fi
                fi
            else
                echo_green ">> Harap buka http://localhost:3000 di browser host Anda."
            fi

            echo_green ">> Menunggu modal userData.json dibuat..."
            while [ ! -f "$ROOT/modal-login/temp-data/userData.json" ]; do
                mkdir -p "$DEST_MODAL_DATA_DIR" || { echo_red "ERROR: Gagal membuat direktori $DEST_MODAL_DATA_DIR"; exit 1; }
                
                if [ -f "$SOURCE_EZLABS_DIR/userApiKey.json" ] && [ -f "$SOURCE_EZLABS_DIR/userData.json" ]; then
                    echo ">> Menemukan userApiKey.json dan userData.json di $SOURCE_EZLABS_DIR, menyalin ke $DEST_MODAL_DATA_DIR..."
                    cp -f "$SOURCE_EZLABS_DIR/userApiKey.json" "$DEST_MODAL_DATA_DIR" || { echo_red "ERROR: Gagal menyalin userApiKey.json."; exit 1; }
                    cp -f "$SOURCE_EZLABS_DIR/userData.json" "$DEST_MODAL_DATA_DIR" || { echo_red "ERROR: Gagal menyalin userData.json."; exit 1; }
                    echo ">> File userData.json dan userApiKey.json berhasil disalin."
                else
                    echo ">> Menunggu file userApiKey.json dan userData.json di $SOURCE_EZLABS_DIR..."
                fi
                
                if [ -f "$SOURCE_EZLABS_DIR/swarm.pem" ] && [ ! -f "$DEST_ROOT_DIR/swarm.pem" ]; then
                    echo ">> Menemukan swarm.pem di $SOURCE_EZLABS_DIR, menyalin ke $DEST_ROOT_DIR..."
                    cp -f "$SOURCE_EZLABS_DIR/swarm.pem" "$DEST_ROOT_DIR" || { echo_red "ERROR: Gagal menyalin swarm.pem."; exit 1; }
                    echo ">> File swarm.pem berhasil disalin."
                fi

                if [ -f "$ROOT/modal-login/temp-data/userData.json" ]; then
                    break
                fi
                sleep 5
            done
            echo "Found userData.json. Proceeding..."
            ;;
            
        n|N)
            echo_green ">> Melanjutkan tanpa login ulang. Memastikan file credential tersedia..."
            mkdir -p "$DEST_MODAL_DATA_DIR" || { echo_red "ERROR: Gagal membuat direktori $DEST_MODAL_DATA_DIR"; exit 1; }
            if [ -f "$SOURCE_EZLABS_DIR/userApiKey.json" ] && \
               [ -f "$SOURCE_EZLABS_DIR/userData.json" ]; then
                echo ">> Menemukan file userApiKey.json dan userData.json di $SOURCE_EZLABS_DIR, menyalin ke $DEST_MODAL_DATA_DIR..."
                cp -f "$SOURCE_EZLABS_DIR/userApiKey.json" "$DEST_MODAL_DATA_DIR" || { echo_red "ERROR: Gagal menyalin userApiKey.json."; exit 1; }
                cp -f "$SOURCE_EZLABS_DIR/userData.json" "$DEST_MODAL_DATA_DIR" || { echo_red "ERROR: Gagal menyalin userData.json."; exit 1; }
                echo ">> File userData.json dan userApiKey.json disalin."
            else
                echo_red "ERROR: File userApiKey.json atau userData.json tidak ditemukan di $SOURCE_EZLABS_DIR. Tidak dapat melanjutkan tanpa login atau file yang ada."
                exit 1
            fi

            if [ -f "$SOURCE_EZLABS_DIR/swarm.pem" ] && [ ! -f "$DEST_ROOT_DIR/swarm.pem" ]; then
                echo ">> Menemukan swarm.pem di $SOURCE_EZLABS_DIR, menyalin ke $DEST_ROOT_DIR..."
                cp -f "$SOURCE_EZLABS_DIR/swarm.pem" "$DEST_ROOT_DIR" || { echo_red "ERROR: Gagal menyalin swarm.pem."; exit 1; }
                echo ">> File swarm.pem disalin."
            fi
            
            if [ ! -f "$ROOT/modal-login/temp-data/userData.json" ]; then
                echo_red "ERROR: userData.json tidak ditemukan setelah proses salin atau verifikasi."
                exit 1
            fi
            ;;
        *)
            echo_red ">> Perintah tidak valid untuk login_status."
            exit 1;
            ;;
    esac

    cd ..

    ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' modal-login/temp-data/userData.json)
    echo "ORG_ID Anda telah disetel ke: $ORG_ID"

    echo "Menunggu API key diaktifkan..."
    while true; do
        STATUS=$(curl -s "http://localhost:3000/api/get-api-key-status?orgId=$ORG_ID")
        if [[ "$STATUS" == "activated" ]]; then
            echo "API key telah diaktifkan! Melanjutkan..."
            break
        else
            echo "Menunggu API key diaktifkan..."
            sleep 5
        fi
    done
fi

echo_green ">> Mengambil dependensi Python..."
pip install --upgrade pip

pip install gensyn-genrl==0.1.4
pip install reasoning-gym>=0.1.20 # untuk reasoning gym env
pip install trl # untuk grpo config, akan segera usang
pip install hivemind@git+https://github.com/gensyn-ai/hivemind@639c964a8019de63135a2594663b5bec8e5356dd # Membutuhkan versi terbaru


if [ ! -d "$ROOT/configs" ]; then
    mkdir "$ROOT/configs"
fi  
if [ -f "$ROOT/configs/rg-swarm.yaml" ]; then
    if ! cmp -s "$ROOT/rgym_exp/config/rg-swarm.yaml" "$ROOT/configs/rg-swarm.yaml"; then
        if [ -z "$GENSYN_RESET_CONFIG" ]; then
            echo_green ">> Ditemukan perbedaan di rg-swarm.yaml. Jika ingin mereset ke default, set GENSYN_RESET_CONFIG ke nilai non-kosong."
        else
            echo_green ">> Ditemukan perbedaan di rg-swarm.yaml. Mencadangkan konfigurasi yang ada."
            mv "$ROOT/configs/rg-swarm.yaml" "$ROOT/configs/rg-swarm.yaml.bak"
            cp "$ROOT/rgym_exp/config/rg-swarm.yaml" "$ROOT/configs/rg-swarm.yaml"
        fi
    fi
else
    cp "$ROOT/rgym_exp/config/rg-swarm.yaml" "$ROOT/configs/rg-swarm.yaml"
fi

if [ -n "$DOCKER" ]; then
    sudo chmod -R 0777 /home/gensyn/rl_swarm/configs
fi

echo_green ">> Selesai persiapan!"

export HUGGINGFACE_ACCESS_TOKEN="None"
echo_green ">> Tidak mendorong model ke Hugging Face Hub secara otomatis."

export MODEL_NAME="$AUTO_MODEL_NAME"
echo_green ">> Menggunakan model: $MODEL_NAME"

echo_green ">> Good luck in the swarm!"
echo_blue ">> Dan ingat untuk memberi bintang repo di GitHub! --> https://github.com/gensyn-ai/rl-swarm"

stop_loop="false"

# --- Main loop (restarts unless stopped) ---
TEMP_LOG_FILE="$ROOT/logs/temp_swarm_launcher_output.log"
FINAL_LOG_FILE="$ROOT/logs/swarm_launcher.log"
PID_FILE="$ROOT/logs/gensyn_runner.pid"

LAST_ACTIVITY_TIME=$(date +%s)
STUCK_TIMEOUT_SECONDS=3600 
ACTIVITY_KEYWORDS=("Joining round:" "Starting round:" "Map: 100%" "INFO] - Reasoning Gym Data Manager initialized" "INFO] - ✅ Connected to Gensyn Testnet" "INFO] - Peer ID" "INFO] - bootnodes:" "INFO] - Using Model:")

while [ "$stop_loop" = "false" ]; do
    echo ">> Memulai rgym swarm launcher pada $(date +'%Y-%m-%d %H:%M:%S')..."
    
    # Kosongkan file PID sebelum memulai proses baru
    > "$PID_FILE" || true

    # Jalankan Python di subshell yang benar-benar terpisah
    # Ini memastikan bahwa jika subshell crash, shell induk (script ini) tidak langsung mati.
    # The 'exec' command here is crucial. It replaces the current subshell with the python process,
    # ensuring the PID we get is directly for python, and its exit code propagates correctly.
    # The | tee "$TEMP_LOG_FILE" & outside the ( ) sends the output to tee in background.
    (
        cd "$ROOT" # Pastikan berada di direktori yang benar
        # Jalankan python dan kirim outputnya ke pipe
        python -m rgym_exp.runner.swarm_launcher \
            --config-path "$ROOT/rgym_exp/config" \
            --config-name "rg-swarm.yaml" 2>&1 &
        PYTHON_ACTUAL_PID=$! # Dapatkan PID dari python
        echo "$PYTHON_ACTUAL_PID" >&3 # Tulis PID ke file descriptor 3
        # Tangani exit code python: jika non-nol, catat agar tee tidak menerima EOF dan gagal
        wait $PYTHON_ACTUAL_PID
        EXIT_CODE=$?
        exit $EXIT_CODE # Pastikan exit code subshell adalah exit code python
    ) 3> "$PID_FILE" | tee "$TEMP_LOG_FILE" & # Output dari subshell pipa ke tee, tee juga di background

    # Simpan PID dari proses Tee
    TEE_PID=$!
    echo ">> Proses Tee untuk Gensyn RL Swarm diluncurkan dengan PID: $TEE_PID"

    # Beri waktu sebentar agar PID dari Python di dalam subshell ditulis ke file
    sleep 2 
    
    # Baca PID dari Python dari file dengan loop retry
    PYTHON_ACTUAL_PID=""
    for i in {1..5}; do # Coba 5 kali
        if [ -s "$PID_FILE" ]; then
            PYTHON_ACTUAL_PID=$(cat "$PID_FILE")
            break
        fi
        sleep 1
    done

    if [ -z "$PYTHON_ACTUAL_PID" ] || [ ! -e "/proc/$PYTHON_ACTUAL_PID" ]; then
        echo_red ">> GAGAL memulai Gensyn RL Swarm. Tidak dapat mendapatkan PID Python yang valid atau proses Python tidak berjalan. Memulai ulang dalam 5 detik..."
        if [ -f "$TEMP_LOG_FILE" ]; then
            cat "$TEMP_LOG_FILE" >> "$FINAL_LOG_FILE"
            rm -f "$TEMP_LOG_FILE"
        fi
        # Bunuh juga proses tee jika masih berjalan dari kegagalan ini
        if [ -n "$TEE_PID" ] && kill -0 "$TEE_PID" 2>/dev/null; then
            kill "$TEE_PID" 2>/dev/null || true
            wait "$TEE_PID" 2>/dev/null || true
        fi
        sleep 5
        continue # Lanjutkan ke iterasi loop berikutnya untuk mencoba lagi
    fi

    echo ">> Proses Python Gensyn yang dipantau memiliki PID: $PYTHON_ACTUAL_PID"

    # Reset waktu aktivitas terakhir
    LAST_ACTIVITY_TIME=$(date +%s)

    MONITOR_INTERVAL=10
    MONITOR_LOOP_STOP="false"

    # Monitor PID dari proses Python yang sebenarnya
    while [ "$MONITOR_LOOP_STOP" = "false" ]; do
        # Periksa apakah proses Python Gensyn masih berjalan
        if ! kill -0 "$PYTHON_ACTUAL_PID" 2>/dev/null; then
            echo_green ">> Proses Python Gensyn (PID: $PYTHON_ACTUAL_PID) telah selesai atau crash."
            MONITOR_LOOP_STOP="true"
            break
        fi

        CURRENT_TIME=$(date +%s)
        
        # Cari aktivitas baru di log sementara
        if grep -qE "$(IFS='|'; echo "${ACTIVITY_KEYWORDS[*]}")" "$TEMP_LOG_FILE"; then
            LAST_ACTIVITY_TIME=$CURRENT_TIME
            > "$TEMP_LOG_FILE" # Mengosongkan file log sementara untuk iterasi berikutnya
            echo ">> Deteksi aktivitas baru. Waktu terakhir aktivitas diperbarui."
        fi

        # Periksa timeout stuck
        if (( CURRENT_TIME - LAST_ACTIVITY_TIME > STUCK_TIMEOUT_SECONDS )); then
            echo_red ">> PERINGATAN: Gensyn RL Swarm (PID: $PYTHON_ACTUAL_PID) tampaknya STUCK (tidak ada aktivitas log dalam ${STUCK_TIMEOUT_SECONDS} detik)! Memaksa restart..."
            kill "$PYTHON_ACTUAL_PID" 2>/dev/null || true
            MONITOR_LOOP_STOP="true"
            break
        fi

        sleep "$MONITOR_INTERVAL"
    done

    # Setelah loop pemantauan selesai (baik karena proses selesai/crash atau stuck)
    # Catat seluruh output TEMP_LOG_FILE ke FINAL_LOG_FILE sebelum dihapus
    if [ -f "$TEMP_LOG_FILE" ]; then
        cat "$TEMP_LOG_FILE" >> "$FINAL_LOG_FILE"
        rm -f "$TEMP_LOG_FILE"
    fi

    # Sekarang tunggu proses tee yang sedang berjalan di background.
    # Ini memastikan semua output telah ditulis ke FINAL_LOG_FILE.
    if [ -n "$TEE_PID" ]; then
        wait "$TEE_PID" 2>/dev/null || true # Tunggu tee selesai menulis
        # Dapatkan exit status dari tee, ini bisa memberi tahu kita jika pipa rusak
        TEE_EXIT_STATUS=$?
        if [ "$TEE_EXIT_STATUS" -ne 0 ]; then
            echo_red ">> Peringatan: Proses tee (PID: $TEE_PID) keluar dengan status $TEE_EXIT_STATUS. Mungkin ada masalah pipa."
        fi
    fi
    
    SHOULD_RESTART_AFTER_CHECK="false"

    # Periksa apakah ada ERROR/Exception/BlockingIOError/EOFError/FileNotFoundError di log
    if cat "$FINAL_LOG_FILE" | tail -n 1000 | grep -qE "ERROR|Exception occurred|P2PDaemonError|BlockingIOError|EOFError|FileNotFoundError|HTTPError"; then # Tambahkan HTTPError
        echo_red ">> Proses Gensyn RL Swarm selesai dengan ERROR/Exception di log. Memulai ulang..."
        SHOULD_RESTART_AFTER_CHECK="true"
    elif [ "$MONITOR_LOOP_STOP" = "true" ] && ! kill -0 "$PYTHON_ACTUAL_PID" 2>/dev/null && (( CURRENT_TIME - LAST_ACTIVITY_TIME >= STUCK_TIMEOUT_SECONDS )); then
        echo_red ">> Proses Gensyn RL Swarm (PID: $PYTHON_ACTUAL_PID) berhenti karena STUCK. Memulai ulang..."
        SHOULD_RESTART_AFTER_CHECK="true"
    else
        echo_green ">> Proses Gensyn RL Swarm selesai dengan sukses (tidak ada error, stuck, atau kode keluar non-nol terdeteksi). Keluar dari loop auto-restart."
        SHOULD_RESTART_AFTER_CHECK="false"
    fi

    if [ "$SHOULD_RESTART_AFTER_CHECK" = "true" ]; then
        echo ">> Memulai ulang dalam 5 detik..."
        sleep 5
    else
        stop_loop="true"
    fi
done

echo ">> Keluar."

# Aktifkan trap cleanup EXIT setelah main loop selesai sepenuhnya.
trap cleanup EXIT