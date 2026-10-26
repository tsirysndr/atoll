import dagger/client
import dagger/container
import dagger/mod
import dagger/mod/argument
import dagger/mod/codec
import dagger/types

pub fn hello(
  _context: mod.Context,
  name: String,
) -> Result(String, codec.Error) {
  Ok("Hello, " <> name <> "!")
}

pub fn container_echo(
  context: mod.Context,
  message: String,
) -> Result(types.Container, codec.Error) {
  Ok(
    context.client
    |> client.container
    |> container.from("alpine:3.22")
    |> container.with_exec(["echo", message]),
  )
}

pub fn definition() -> mod.Object {
  mod.object("__OBJECT__")
  |> mod.with_function(mod.function(
    "hello",
    argument.required("name", codec.string()),
    codec.string(),
    hello,
  ))
  |> mod.with_function(mod.function(
    "container_echo",
    argument.required("message", codec.string()),
    container.codec(),
    container_echo,
  ))
}

pub fn main() {
  let assert Ok(_) = mod.serve(definition(), [])
}
