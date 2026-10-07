sysctl -w vm.dirty_background_bytes=536870912   # 512MB
sysctl -w vm.dirty_bytes=2147483648             # 2GB
sysctl -w vm.min_free_kbytes=4194304            # 4GB 
sysctl -w vm.swappiness=1
