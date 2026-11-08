{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.gokapi;
  settingsFormat = pkgs.formats.json { };
  settingsJson = settingsFormat.generate "gokapi-settings.json" cfg.settings;

  # Persistent variables are only read by the setup wizard. Each maps to its setting.
  # See https://gokapi.readthedocs.io/en/latest/advanced.html#availenvvar
  setupOnlyEnvironment = {
    GOKAPI_PORT = "Port";
    GOKAPI_DATA_DIR = "DataDir";
    GOKAPI_MAX_FILESIZE = "MaxFileSizeMB";
    GOKAPI_MAX_MEMORY_UPLOAD = "MaxMemory";
    GOKAPI_CHUNK_SIZE_MB = "ChunkSize";
    GOKAPI_MAX_PARALLEL_UPLOADS = "MaxParallelUploads";
  };

  # Kept from the previous config file. New salts invalidate stored passwords.
  keptFromPrevious =
    if cfg.mutableSettings then
      "."
    else
      ''
        {
          ConfigVersion: $version,
          Authentication: {
            SaltAdmin: (.Authentication.SaltAdmin // $newSaltAdmin),
            SaltFiles: (.Authentication.SaltFiles // $newSaltFiles)
          }
        }
      '';

  prepare = pkgs.writeShellApplication {
    name = "gokapi-prepare";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      cfg.package
    ];
    text = ''
      config="$GOKAPI_CONFIG_DIR/$GOKAPI_CONFIG_FILE"
      mkdir -p "$GOKAPI_CONFIG_DIR"
      ${
        if cfg.mutableSettings then
          ''[[ -f "$config" ]] || exit 0 # a new install runs the setup wizard''
        else
          ''[[ -f "$config" ]] || echo '{}' > "$config"''
      }
      if [[ -f "$config" ]] && ! jq -e 'type == "object"' "$config" > /dev/null 2>&1; then
        echo "$config is empty or not a JSON object. Fix or delete it." >&2
        exit 1
      fi
      # Deep merge. Later files win.
      jq -n \
        --argjson version "$(< ${cfg.package}/share/gokapi/config-version)" \
        --arg newSaltAdmin "$(head -c 24 /dev/urandom | base64)" \
        --arg newSaltFiles "$(head -c 24 /dev/urandom | base64)" \
        'reduce inputs as $part (input | ${keptFromPrevious}; . * $part)' \
        "$config" ${settingsJson} ${
          lib.optionalString (cfg.settingsFile != null) ''"$CREDENTIALS_DIRECTORY/settings"''
        } > "$config.tmp"
      mv "$config.tmp" "$config"
    ''
    + lib.optionalString (cfg.passwordFile != null) ''
      # Applying the password logs the super admin out, so only apply a changed one.
      # The admin salt is in the hash, so a rebuilt config file gets the password again.
      password_hash() {
        { jq -j .Authentication.SaltAdmin "$config"; cat "$CREDENTIALS_DIRECTORY/password"; } | sha256sum
      }
      applied="$STATE_DIRECTORY/password.sha256"
      if [[ "$(cat "$applied" 2> /dev/null)" != "$(password_hash)" ]]; then
        # The password is briefly visible in argv. Gokapi cannot read it from a file.
        # TODO: remove when fixed
        gokapi --deployment-password "$(< "$CREDENTIALS_DIRECTORY/password")"
        # Gokapi sets a new admin salt with the password.
        password_hash > "$applied"
      fi
    '';
  };
in
{
  options.services.gokapi = {
    enable = lib.mkEnableOption "Lightweight selfhosted Firefox Send alternative without public upload";

    mutableSettings = lib.mkOption {
      type = lib.types.bool;
      default = lib.versionOlder config.system.stateVersion "26.11";
      defaultText = lib.literalExpression ''lib.versionOlder config.system.stateVersion "26.11"'';
      description = ''
        Whether to keep gokapi's config file across restarts.
        {option}`services.gokapi.settings` is merged over it.
        A new install runs gokapi's setup wizard.
        If disabled, the config file is rebuilt from {option}`services.gokapi.settings` on every start.
        Only the password salts are kept.
      '';
    };

    package = lib.mkPackageOption pkgs "gokapi" { };

    environment = lib.mkOption {
      type = lib.types.submodule {
        freeformType = lib.types.attrsOf (lib.types.either lib.types.str lib.types.int);
        options = {
          GOKAPI_CONFIG_DIR = lib.mkOption {
            type = lib.types.str;
            default = "%S/gokapi/config";
            description = "Sets the directory for the config file.";
          };
          GOKAPI_CONFIG_FILE = lib.mkOption {
            type = lib.types.str;
            default = "config.json";
            description = "Sets the filename for the config file.";
          };
        };
      };
      default = { };
      example = {
        GOKAPI_TRUSTED_PROXIES = "127.0.0.1,10.0.0.0/24";
      };
      description = ''
        Environment variables for gokapi.
        Systemd specifiers are allowed.
        See <https://gokapi.readthedocs.io/en/latest/advanced.html#availenvvar>.
        Persistent variables are only read by the setup wizard.
        They are not allowed if {option}`services.gokapi.mutableSettings` is disabled.
        Use {option}`services.gokapi.settings` instead.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.externalPath;
      default = null;
      example = "/run/secrets/gokapi.env";
      description = "Environment file for secrets. See {manpage}`systemd.exec(5)`.";
    };

    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.externalPath;
      default = null;
      example = "/run/secrets/gokapi-admin-password";
      description = ''
        File with the super admin password.
        The super admin is `settings.Authentication.Username`.
        It is applied when the file changes. This logs the super admin out.
        A password changed in the web interface stays until the file changes.
        If {option}`services.gokapi.mutableSettings` is disabled, no setup wizard is needed.
        See <https://gokapi.readthedocs.io/en/latest/advanced.html#autodeployment>.
      '';
    };

    settings = lib.mkOption {
      type = settingsFormat.type;
      default = { };
      example = {
        ServerUrl = "https://gokapi.example.com/";
      };
      description = ''
        Gokapi's config file.
        See <https://gokapi.readthedocs.io/en/latest/advanced.html#autodeployment>.
        `ServerUrl` is required if {option}`services.gokapi.mutableSettings` is disabled.
      '';
    };

    settingsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        JSON file merged over {option}`services.gokapi.settings`.
        It keeps secrets out of the Nix store.
        Systemd specifiers are allowed.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.mutableSettings || cfg.settings ? ServerUrl;
        message = "services.gokapi.settings.ServerUrl must be set if services.gokapi.mutableSettings is disabled.";
      }
    ]
    ++ lib.mapAttrsToList (variable: setting: {
      assertion = cfg.mutableSettings || !cfg.environment ? ${variable};
      message = "services.gokapi.environment.${variable} is only read by the setup wizard. Set services.gokapi.settings.${setting} instead.";
    }) setupOnlyEnvironment;

    services.gokapi = {
      environment = {
        GOKAPI_LOG_STDOUT = lib.mkDefault "true";
        # Large uploads are buffered here. /tmp may be in RAM.
        TMPDIR = lib.mkDefault "%C/gokapi";
      };
      # Setup wizard defaults. Their zero values do not work.
      settings = lib.mkIf (!cfg.mutableSettings) {
        Authentication.Username = lib.mkDefault "admin";
        Port = lib.mkDefault "127.0.0.1:53842";
        RedirectUrl = lib.mkDefault "https://github.com/Forceu/Gokapi/";
        DataDir = lib.mkDefault "/var/lib/gokapi/data";
        DatabaseUrl = lib.mkDefault "sqlite:///var/lib/gokapi/data/gokapi.sqlite";
        MaxFileSizeMB = lib.mkDefault 102400;
        MaxMemory = lib.mkDefault 50;
      };
    };

    systemd.services.gokapi = {
      description = "Gokapi file sharing server";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      environment = lib.mapAttrs (_: toString) cfg.environment;
      serviceConfig = {
        ExecStartPre = lib.getExe prepare;
        ExecStart = lib.getExe cfg.package;
        EnvironmentFile = lib.mkIf (cfg.environmentFile != null) cfg.environmentFile;
        LoadCredential =
          lib.optional (cfg.settingsFile != null) "settings:${cfg.settingsFile}"
          ++ lib.optional (cfg.passwordFile != null) "password:${cfg.passwordFile}";
        # Gokapi reads ./custom. See https://gokapi.readthedocs.io/en/latest/advanced.html#customising
        WorkingDirectory = "%S/gokapi";
        StateDirectory = "gokapi";
        CacheDirectory = "gokapi";
        Restart = "on-failure";
        RestartSec = 30;

        DynamicUser = true;
        UMask = "0077";
        CapabilityBoundingSet = "";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        PrivateUsers = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        # No ProcSubset = "pid". The status page panics without /proc/stat.
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        # AF_NETLINK: the setup wizard lists interfaces to print its address.
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
      };
    };
  };

  meta.maintainers = with lib.maintainers; [ delliott ];
}
