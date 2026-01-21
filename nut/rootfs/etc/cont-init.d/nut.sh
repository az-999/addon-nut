#!/command/with-contenv bashio
# ==============================================================================
# Home Assistant Community Add-on: Network UPS Tools
# Configures Network UPS Tools
# ==============================================================================
readonly USERS_CONF=/etc/nut/upsd.users
readonly UPSD_CONF=/etc/nut/upsd.conf
declare nutmode
declare password
declare shutdowncmd
declare upsmonpwd
declare username

# Debug: Output configuration
bashio::log.info "=== Addon configuration debug ==="
if [ -f /data/options.json ]; then
    bashio::log.info "Configuration file exists: /data/options.json"
    bashio::log.info "Configuration content:"
    cat /data/options.json | while IFS= read -r line; do
        bashio::log.info "  ${line}"
    done
else
    bashio::log.warning "Configuration file /data/options.json not found!"
fi

# Output key configuration values
bashio::log.info "Key config values:"
bashio::log.info "  mode: $(bashio::config 'mode' 2>/dev/null || echo 'not set')"
bashio::log.info "  shutdown_host: $(bashio::config 'shutdown_host' 2>/dev/null || echo 'not set')"
if bashio::config.has_value "devices"; then
    bashio::log.info "  devices count: $(bashio::config "devices|length" 2>/dev/null || echo 'unknown')"
    for device in $(bashio::config "devices|keys" 2>/dev/null); do
        bashio::log.info "    device[${device}]: name=$(bashio::config "devices[${device}].name" 2>/dev/null), driver=$(bashio::config "devices[${device}].driver" 2>/dev/null)"
    done
else
    bashio::log.info "  devices: not set"
fi
bashio::log.info "=== End of configuration debug ==="

chown root:root /var/run/nut
chmod 0770 /var/run/nut

chown -R root:root /etc/nut
find /etc/nut -not -perm 0660 -type f -exec chmod 0660 {} \;
find /etc/nut -not -perm 0660 -type d -exec chmod 0660 {} \;

nutmode=$(bashio::config 'mode')
bashio::log.info "Setting mode to ${nutmode}..."
sed -i "s#%%nutmode%%#${nutmode}#g" /etc/nut/nut.conf

if bashio::config.true 'list_usb_devices' ;then
    bashio::log.info "Connected USB devices:"
    lsusb
fi

if bashio::config.equals 'mode' 'netserver' ;then
    bashio::log.info "Generating ${USERS_CONF}..."

    # Create Monitor User
    upsmonpwd=$(shuf -ze -n20  {A..Z} {a..z} {0..9}|tr -d '\0')
    {
        echo
        echo "[upsmonmaster]"
        echo "  password = ${upsmonpwd}"
        echo "  upsmon master"
    } >> "${USERS_CONF}"

    # Create hardcoded user
    {
        echo
        echo "[nut]"
        echo "  password = nut"
        echo "  instcmds = all"
    } >> "${USERS_CONF}"

    if bashio::config.has_value "upsd_maxage"; then
        maxage=$(bashio::config "upsd_maxage")
        echo "MAXAGE ${maxage}" >> "${UPSD_CONF}"
    fi

    # Hardcoded configuration for RICHCOMM UPS USB Mon V2.0
    bashio::log.info "Configuring hardcoded RICHCOMM UPS device..."
    {
        echo
        echo "[myups]"
        echo "  driver = nutdrv_qx"
        echo "  port = auto"
        echo "  vendorid = 0925"
        echo "  productid = 1234"
        echo "  subdriver = armac"
    } >> /etc/nut/ups.conf

    echo "MONITOR myups@localhost 1 upsmonmaster ${upsmonpwd} master" \
        >> /etc/nut/upsmon.conf

    # Debug: Check if driver exists
    bashio::log.info "Checking for nutdrv_qx driver..."
    if [ -f /usr/lib/nut/nutdrv_qx ] || [ -f /usr/libexec/nut/nutdrv_qx ] || [ -f /usr/bin/nutdrv_qx ]; then
        bashio::log.info "Driver nutdrv_qx found"
        find /usr -name "nutdrv_qx" 2>/dev/null | head -3 | while IFS= read -r driver_path; do
            bashio::log.info "  Found at: ${driver_path}"
        done
    else
        bashio::log.error "Driver nutdrv_qx NOT FOUND in standard locations!"
        bashio::log.info "Searching for nutdrv_qx in /usr..."
        find /usr -name "nutdrv_qx" 2>/dev/null | head -5 | while IFS= read -r driver_path; do
            bashio::log.info "  Found at: ${driver_path}"
        done || bashio::log.warning "  No nutdrv_qx driver found anywhere in /usr"
    fi

    # Debug: Output UPS configuration file content
    bashio::log.info "UPS configuration file (/etc/nut/ups.conf) content:"
    while IFS= read -r line; do
        bashio::log.info "  ${line}"
    done < /etc/nut/ups.conf

    bashio::log.info "Starting the UPS drivers with maximum debug output..."
    # Run upsdrvctl with maximum debug and capture all output
    driver_exit_code=0
    {
        upsdrvctl -u root -DDDDD start 2>&1
        driver_exit_code=${PIPESTATUS[0]}
    } | while IFS= read -r line; do
        bashio::log.info "DRIVER: ${line}"
    done
    
    # Check if driver socket was created
    bashio::log.info "Checking for driver socket..."
    if [ -S /run/nut/nutdrv_qx-myups ]; then
        bashio::log.info "Driver socket created successfully: /run/nut/nutdrv_qx-myups"
        ls -la /run/nut/nutdrv_qx-myups
    else
        bashio::log.warning "Driver socket NOT found: /run/nut/nutdrv_qx-myups"
        bashio::log.info "Contents of /run/nut/ directory:"
        ls -la /run/nut/ 2>/dev/null | while IFS= read -r line; do
            bashio::log.info "  ${line}"
        done || bashio::log.warning "  Directory /run/nut/ not accessible or empty"
    fi
    
    # If driver failed, log warning but continue
    if [ "${driver_exit_code}" -ne 0 ]; then
        bashio::log.warning "UPS driver failed to start (exit code: ${driver_exit_code})"
        bashio::log.warning "This might be due to:"
        bashio::log.warning "1. USB device not connected or not recognized"
        bashio::log.warning "2. Insufficient permissions to access USB device"
        bashio::log.warning "3. Wrong driver or port configuration"
        bashio::log.warning "4. Driver nutdrv_qx not compatible with this UPS model"
        bashio::log.warning "Please check your USB connection and addon configuration."
        bashio::log.warning "Addon will continue to run, but UPS monitoring may not work."
        bashio::log.warning "To debug, enable 'list_usb_devices: true' in addon configuration."
    else
        bashio::log.info "UPS driver started successfully"
    fi
fi

shutdowncmd="/run/s6/basedir/bin/halt"
if bashio::config.true 'shutdown_host'; then
    bashio::log.warning "UPS Shutdown will shutdown the host"
    shutdowncmd="/usr/bin/shutdownhost"
fi

echo "SHUTDOWNCMD  ${shutdowncmd}" >> /etc/nut/upsmon.conf
