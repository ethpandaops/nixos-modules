# A local webhook that appends "<path> <body>" for every POST to
# /var/lib/notify-sink.log, so tests can see what nixhost-notify sent. Like
# Discord, paths under /api/webhooks/ want {"content": ...}, or
# {"text": ...} when they end in /slack, and answer 400 otherwise.
{ pkgs, ... }:
{
  systemd.services.notify-sink = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig.ExecStart = "${pkgs.python3.interpreter} ${pkgs.writeText "notify-sink.py" ''
      import http.server, json

      class Handler(http.server.BaseHTTPRequestHandler):
          def do_POST(self):
              body = self.rfile.read(int(self.headers["Content-Length"]))
              with open("/var/lib/notify-sink.log", "ab") as log:
                  log.write(self.path.encode() + b" " + body + b"\n")
              if self.path.startswith("/api/webhooks/"):
                  field = "text" if self.path.endswith("/slack") else "content"
                  if field not in json.loads(body):
                      self.send_response(400)
                      self.end_headers()
                      self.wfile.write(b'{"message": "Cannot send an empty message", "code": 50006}')
                      return
              self.send_response(204)
              self.end_headers()

      http.server.HTTPServer(("127.0.0.1", 8000), Handler).serve_forever()
    ''}";
  };
}
