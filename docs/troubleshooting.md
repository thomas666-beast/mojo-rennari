# Troubleshooting

[Documentation home](README.md)

| Symptom | What to check |
| --- | --- |
| Cannot locate YAML/PP.pm | Install YAML::PP for the generated project |
| Cannot locate Mojo/Rennari/... | Install your distribution or correct Perl's library search path |
| TOKEN_APP configuration error | Replace CHANGE_ME; match the 32–256-character starter rule |
| Handshake failed / 401 | Match TOKEN_APP; verify custom header forwarding and your user auth logic |
| Handshake / 500 | Check server logs for missing auth_cb, callback exception, identity type or recovery identity id |
| Bad frame / 4002 | Match serializers, validate envelope, inspect input size limit |
| Unknown event / 4003 | Register that event in the correct namespace; verify exact spelling |
| Handler error / 4004 | Inspect exception logs and automatic-reply serialization |
| Unknown namespace / 4005 | Register namespace server-side and create client namespace before connect |
| Recovery disabled / 4006 | Remove resume request or explicitly enable server recovery |
| Extra reply event | End send-only handlers with return undef |
| Only the last handler runs | Registrations replace earlier callbacks for the same namespace/event |
| Client stops on error | Generated lifecycle code deliberately stops; core behavior may differ |
| Idle connection closes | Check server inactivity timeout, heartbeat policy and proxy timeouts |
| No replay of missed room broadcasts | Offline members are detached; current recovery does not buffer those broadcasts |
| Recovery fails after restart or another worker | Recovery is process-local and in-memory |
| Setting YAML option does nothing | Explicitly validate and pass extra options into the constructor |
| Browser cannot reproduce Perl handshake | Browser client/authentication design is not supplied; do not expose TOKEN_APP |

## Diagnose without exposing secrets

Start with local loopback, matching serializers and a simple ping/pong event. Inspect HTTP status and server error category before examining application payloads. Never paste a live TOKEN_APP, user token or recovery session id into public logs or bug reports.

For a useful bug report, include the Rennari version, Perl/Mojolicious versions, generated style, serializer, close code, sanitized error messages and a minimal reproduction with replacement credentials.
