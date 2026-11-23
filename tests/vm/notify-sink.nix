# A local webhook that appends every POST body to /var/lib/notify-sink.log,
# so tests can see what nixhost-notify sent.
{ pkgs, ... }:
{
  systemd.services.notify-sink = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig.ExecStart = "${pkgs.python3.interpreter} ${pkgs.writeText "notify-sink.py" ''
      import http.server

      class Handler(http.server.BaseHTTPRequestHandler):
          def do_POST(self):
              body = self.rfile.read(int(self.headers["Content-Length"]))
              with open("/var/lib/notify-sink.log", "ab") as log:
                  log.write(body + b"\n")
              self.send_response(204)
              self.end_headers()

      http.server.HTTPServer(("127.0.0.1", 8000), Handler).serve_forever()
    ''}";
  };
}
