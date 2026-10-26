import ci
import dagger
import dagger/connection
import dagger/directory
import dagger/mod/codec
import dagger/types
import gleam/dynamic/decode
import gleam/json
import gleam/string

fn check(
  old_paths: String,
  new_paths: String,
  changed: Bool,
) -> Result(String, codec.Error) {
  let conn =
    connection.with_transport(fn(body) {
      let assert Ok(query) =
        json.parse(body, decode.at(["query"], decode.string))
      let old = string.contains(query, "\"before\"")
      let data = case string.contains(query, "glob(") {
        True ->
          "{\"glob\":"
          <> {
            case old {
              True -> old_paths
              False -> new_paths
            }
          }
          <> "}"
        False -> {
          // Regressions to metadata-sensitive hashing must fail this test.
          let assert True =
            string.contains(query, "digest(excludeMetadata:true)")
          let hash = case !old && changed && string.contains(query, "app.js") {
            True -> "different"
            False -> "same-bytes"
          }
          "{\"file\":{\"digest\":\"" <> hash <> "\"}}"
        }
      }
      Ok(#(200, "{\"data\":{\"node\":" <> data <> "}}"))
    })
  let client = dagger.from_connection(conn)
  ci.unchanged(
    directory.from_id(client, types.Id("before")),
    directory.from_id(client, types.Id("after")),
  )
}

pub fn main() {
  let paths = "[\"app.js\",\"assets/\",\"assets/style.css\"]"
  let assert Ok(_) = check(paths, paths, False)
  let assert Error(codec.FunctionError(message)) = check(paths, paths, True)
  let assert True = string.contains(message, "app.js")
  let assert Error(codec.FunctionError(message)) =
    check(paths, "[\"app.js\"]", False)
  let assert True = string.contains(message, "assets/style.css")
  let assert Error(codec.FunctionError(message)) =
    check("[\"app.js\"]", paths, False)
  let assert True = string.contains(message, "assets/style.css")
  let assert Ok(_) = check("[]", "[\"empty/\"]", False)
}
