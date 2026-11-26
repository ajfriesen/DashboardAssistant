# VM test for reloading the kiosk browser (modules/core/kiosk.nix: cdpNav, the
# script the nav agent runs for each line the daemon writes to nav.fifo). The
# daemon writes "reload" for Home Assistant's Reload button, and when the
# device's user becomes an admin: Home Assistant's frontend reads the user once,
# when it loads, so the admin parts only show after a reload.
#
# The real kiosk session needs a GPU, so Chromium runs headless here on the same
# loopback debugging port, on a page that counts its own loads.
{
  pkgs,
  version,
  ...
}:
let
  site = pkgs.runCommand "kiosk-reload-site" { } ''
    mkdir $out
    cat > $out/index.html <<'EOF'
    <script>
      const n = Number(sessionStorage.getItem("loads") || 0) + 1;
      sessionStorage.setItem("loads", n);
      document.title = "load " + n;
    </script>
    EOF
    echo '<title>other</title>' > $out/other.html
  '';
in
pkgs.testers.runNixOSTest {
  name = "kiosk-reload";

  node.specialArgs = {
    inherit version;
    impermanence = null;
  };

  nodes.machine =
    { config, lib, ... }:
    {
      imports = [ ../modules/core/default.nix ];

      systemd.services.greetd.enable = lib.mkForce false;
      virtualisation.memorySize = 2048;
      environment.etc."kiosk-reload-test/nav".source = config.dashboardAssistant.kiosk.nav;

      systemd.services.site = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8000 --bind 127.0.0.1 --directory ${site}";
      };
      systemd.services.headless-chromium = {
        wantedBy = [ "multi-user.target" ];
        after = [ "site.service" ];
        serviceConfig.ExecStart = lib.concatStringsSep " " [
          "${pkgs.chromium}/bin/chromium"
          "--headless=new"
          "--no-sandbox"
          "--disable-gpu"
          "--remote-debugging-port=9222"
          "--remote-allow-origins=*"
          "--user-data-dir=/tmp/chromium"
          "http://127.0.0.1:8000/"
        ];
      };
    };

  testScript = ''
    import json

    def page():
        out = machine.succeed("curl -s http://127.0.0.1:9222/json")
        return [p for p in json.loads(out) if p["type"] == "page"][0]

    def wait_for(title, url):
        def check(_):
            p = page()
            machine.log(f"page: {p['title']!r} at {p['url']}")
            return p["title"] == title and p["url"] == url
        retry(check, timeout_seconds=60)

    machine.start()
    machine.wait_for_open_port(9222, timeout=120)
    wait_for("load 1", "http://127.0.0.1:8000/")

    with subtest("reload loads the same page again"):
        machine.succeed("/etc/kiosk-reload-test/nav reload")
        wait_for("load 2", "http://127.0.0.1:8000/")

    with subtest("a URL still navigates there"):
        machine.succeed("/etc/kiosk-reload-test/nav http://127.0.0.1:8000/other.html")
        wait_for("other", "http://127.0.0.1:8000/other.html")
  '';
}
