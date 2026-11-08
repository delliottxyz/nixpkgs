{ lib, ... }:
let
  port = 6000;
  url = "http://127.0.0.1:${toString port}";
in
{
  name = "gokapi";

  meta.maintainers = with lib.maintainers; [ delliott ];

  nodes = {
    wizard.services.gokapi = {
      enable = true;
      mutableSettings = true;
      environment.GOKAPI_PORT = port;
    };

    declarative = {
      services.gokapi = {
        enable = true;
        mutableSettings = false;
        settings = {
          ServerUrl = "${url}/";
          Port = "127.0.0.1:${toString port}";
        };
        passwordFile = "/run/gokapi-password";
        settingsFile = "/run/gokapi-settings.json";
      };
      systemd.tmpfiles.settings.gokapi = {
        "/run/gokapi-password".f.argument = "first-password";
        "/run/gokapi-settings.json".f.argument = ''{"PublicName":"From settingsFile"}'';
      };

      specialisation.mutable.configuration.services.gokapi = {
        mutableSettings = lib.mkForce true;
        settingsFile = lib.mkForce null;
        settings.PublicName = "From mutable settings";
      };
    };
  };

  testScript = ''
    config = "/var/lib/gokapi/config/config.json"

    def login(password):
        token = declarative.succeed(
            "curl -sf ${url}/login | sed -n 's/.*name=\"csrf-token\" value=\"\\([^\"]*\\)\".*/\\1/p'"
        ).strip()
        return "URL=./admin" in declarative.succeed(
            f"curl -sf ${url}/login -d username=admin -d password={password} -d csrf-token={token}"
        )

    def restart():
        declarative.systemctl("restart gokapi.service")
        declarative.wait_for_open_port(${toString port})

    def file_salt():
        return declarative.succeed(f"grep -o '\"SaltFiles\": \"[^\"]*\"' {config}")

    def switch(system):
        declarative.succeed(f"{system}/bin/switch-to-configuration test")
        restart()

    start_all()

    with subtest("a new mutable install is left to the setup wizard"):
        wizard.wait_for_open_port(${toString port})
        wizard.succeed("curl -sf ${url}/setup/start | grep 'Gokapi Setup'")
        wizard.fail(f"test -e {config}")

    with subtest("declarative install sets the password and merges settingsFile"):
        declarative.wait_for_open_port(${toString port})
        assert login("first-password")
        declarative.succeed("curl -sf ${url}/login | grep 'From settingsFile'")

    def passwords_applied():
        return int(declarative.succeed("journalctl -u gokapi.service | grep -c 'New password has been set' || true"))

    with subtest("the file salt and password are kept across restarts"):
        salt = file_salt()
        restart()
        assert file_salt() == salt
        assert passwords_applied() == 1

    with subtest("a changed passwordFile is applied"):
        declarative.succeed("echo second-password > /run/gokapi-password")
        restart()
        assert login("second-password")
        assert not login("first-password")
        assert passwords_applied() == 2

    with subtest("a corrupt config file stops the service with a clear error"):
        declarative.succeed(f"cp {config} /tmp/config.json && echo '{{' > {config}")
        declarative.fail("systemctl restart gokapi.service")
        declarative.succeed("journalctl -u gokapi.service | grep 'is empty or not a JSON object'")
        declarative.succeed(f"cp /tmp/config.json {config}")
        restart()

    with subtest("mutable mode keeps changes made outside Nix and merges settings"):
        switch("/run/booted-system/specialisation/mutable")
        declarative.succeed(f"sed -i 's/\"MaxFileSizeMB\": [0-9]*/\"MaxFileSizeMB\": 1234/' {config}")
        restart()
        declarative.succeed(f"grep '\"MaxFileSizeMB\": 1234' {config}")
        declarative.succeed("curl -sf ${url}/login | grep 'From mutable settings'")
        assert login("second-password")
        assert file_salt() == salt

    with subtest("switching back to declarative resets settings but keeps the file salt"):
        switch("/run/booted-system")
        declarative.succeed(f"grep '\"MaxFileSizeMB\": 102400' {config}")
        declarative.succeed("curl -sf ${url}/login | grep 'From settingsFile'")
        assert login("second-password")
        assert file_salt() == salt
  '';
}
