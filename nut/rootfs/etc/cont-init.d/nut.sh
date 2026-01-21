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

# Debug: Output full configuration
bashio::log.info "=== Full addon configuration ==="
bashio::log.info "$(bashio::config)"
bashio::log.info "=== End of configuration ==="

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

    bashio::log.info "Starting the UPS drivers..."
    # Run upsdrvctl and capture exit code
    driver_exit_code=0
    if bashio::debug; then
        upsdrvctl -u root -D start || driver_exit_code=$?
    else
        upsdrvctl -u root start || driver_exit_code=$?
    fi
    
    # If driver failed, log warning but continue
    if [ "${driver_exit_code}" -ne 0 ]; then
        bashio::log.warning "UPS driver failed to start (exit code: ${driver_exit_code})"
        bashio::log.warning "This might be due to:"
        bashio::log.warning "1. USB device not connected or not recognized"
        bashio::log.warning "2. Insufficient permissions to access USB device"
        bashio::log.warning "3. Wrong driver or port configuration"
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
