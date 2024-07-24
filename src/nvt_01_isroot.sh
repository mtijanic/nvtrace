if [ "$(id -u)" -ne 0 ]; then
    echo "Not running as root, individual commands may ask for sudo password."
    is_root=0
else
    is_root=1
fi

