//// Define and serve Gleam-authored Dagger modules without runtime reflection.

import dagger
import dagger/internal/query
import dagger/mod/argument.{type Arguments}
import dagger/mod/codec.{
  type Codec, type Error, InvalidDefinition, SdkError, UnknownFunction,
}
import dagger/types
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result

pub type Context {
  Context(client: types.Query, parent: Dynamic)
}

pub opaque type Function {
  Function(
    name: String,
    arguments: List(argument.Definition),
    returns: codec.Type,
    description: String,
    run: fn(Context, Dict(String, Dynamic)) -> Result(json.Json, Error),
  )
}

pub opaque type Object {
  Object(
    name: String,
    description: String,
    functions: List(Function),
    fields: List(Field),
  )
}

type Field {
  Field(
    name: String,
    schema: codec.Type,
    read: fn(Context) -> Result(json.Json, Error),
  )
}

pub fn object(name: String) -> Object {
  Object(name, "", [], [])
}

pub fn with_description(object: Object, description: String) -> Object {
  Object(..object, description: description)
}

pub fn function(
  name: String,
  arguments: Arguments(a),
  returns: Codec(b),
  handler: fn(Context, a) -> Result(b, Error),
) -> Function {
  Function(
    name,
    argument.definitions(arguments),
    codec.schema(returns),
    "",
    fn(context, values) {
      use args <- result.try(argument.decode(arguments, context.client, values))
      use value <- result.try(handler(context, args))
      codec.encode(returns, value)
    },
  )
}

pub fn describe(function: Function, description: String) -> Function {
  Function(..function, description: description)
}

pub fn with_function(object: Object, function: Function) -> Object {
  Object(..object, functions: list.append(object.functions, [function]))
}

/// Constructor handlers return the object's JSON state using codec.object().
pub fn with_constructor(
  object: Object,
  args: Arguments(a),
  state: Codec(b),
  handler: fn(Context, a) -> Result(b, Error),
) -> Object {
  with_function(object, function("", args, state, handler))
}

pub fn with_field(object: Object, name: String, codec: Codec(a)) -> Object {
  let field =
    Field(name, codec.schema(codec), fn(context) {
      use value <- result.try(
        decode.run(context.parent, decode.at([name], decode.dynamic))
        |> result.map_error(fn(_) {
          codec.InvalidValue("Missing object field: " <> name)
        }),
      )
      use value <- result.try(codec.decode(codec, context.client, value))
      codec.encode(codec, value)
    })
  Object(..object, fields: list.append(object.fields, [field]))
}

/// Decode persisted object state within a function handler.
pub fn parent(context: Context, codec: Codec(a)) -> Result(a, Error) {
  codec.decode(codec, context.client, context.parent)
}

/// Serve one invocation. Dagger launches a fresh process for each function call.
pub fn serve(
  root: Object,
  additional_objects: List(Object),
) -> Result(Nil, Error) {
  use client <- result.try(dagger.connect() |> result.map_error(SdkError))
  with_cleanup(
    fn() { serve_with_client(client, root, additional_objects) },
    fn() { dagger.close(client) },
  )
}

@external(erlang, "dagger_ffi", "with_cleanup")
fn with_cleanup(run: fn() -> a, cleanup: fn() -> Nil) -> a

/// Injectable entrypoint for testing the Dagger invocation protocol.
pub fn serve_with_client(
  client: types.Query,
  root: Object,
  additional_objects: List(Object),
) -> Result(Nil, Error) {
  let objects = [root, ..additional_objects]
  use _ <- result.try(validate(objects))
  let decoder = {
    use parent_name <- decode.field("parentName", decode.string)
    use name <- decode.field("name", decode.string)
    use parent <- decode.field("parent", decode.string)
    use args <- decode.field(
      "inputArgs",
      decode.list({
        use name <- decode.field("name", decode.string)
        use value <- decode.field("value", decode.string)
        decode.success(#(name, value))
      }),
    )
    decode.success(#(parent_name, name, parent, args))
  }
  use call <- result.try(
    dagger.execute(
      client,
      "query{currentFunctionCall{parentName name parent inputArgs{name value}}}",
      decode.at(["currentFunctionCall"], decoder),
    )
    |> result.map_error(SdkError),
  )
  use value <- result.try(case call.0 {
    "" -> register(client, objects)
    parent_name -> {
      use parent <- result.try(case call.2 {
        "" -> Ok(dynamic.properties([]))
        _ -> parse(call.2)
      })
      use args <- result.try(
        list.try_map(call.3, fn(arg) {
          use value <- result.try(parse(arg.1))
          Ok(#(arg.0, value))
        }),
      )
      invoke(
        objects,
        parent_name,
        call.1,
        Context(client, parent),
        dict.from_list(args),
      )
    }
  })
  query.root(query.connection(client.selection))
  |> query.select("currentFunctionCall", [])
  |> query.select("returnValue", [
    #("value", query.String(json.to_string(value))),
  ])
  |> query.execute(decode.dynamic)
  |> result.map(fn(_) { Nil })
  |> result.map_error(SdkError)
}

fn parse(value: String) -> Result(Dynamic, Error) {
  json.parse(value, decode.dynamic)
  |> result.map_error(fn(_) {
    codec.InvalidValue("Invalid JSON in Dagger function call")
  })
}

/// Dispatch is public to permit fast, engine-free module tests.
pub fn invoke(
  objects: List(Object),
  object_name: String,
  name: String,
  context: Context,
  arguments: Dict(String, Dynamic),
) -> Result(json.Json, Error) {
  use object <- result.try(
    list.find(objects, fn(o) { o.name == object_name })
    |> result.map_error(fn(_) { UnknownFunction(object_name, name) }),
  )
  case list.find(object.functions, fn(f) { f.name == name }) {
    Ok(function) -> function.run(context, arguments)
    Error(_) if name == "" -> Ok(json.object([]))
    Error(_) ->
      case list.find(object.fields, fn(f) { f.name == name }) {
        Ok(field) -> field.read(context)
        Error(_) -> Error(UnknownFunction(object_name, name))
      }
  }
}

/// Validate duplicates before any request is sent to the engine.
pub fn validate(objects: List(Object)) -> Result(Nil, Error) {
  use _ <- result.try(unique(list.map(objects, fn(o) { o.name })))
  list.try_each(objects, fn(object) {
    use _ <- result.try(
      unique(list.append(
        list.map(object.functions, fn(f) { f.name }),
        list.map(object.fields, fn(f) { f.name }),
      )),
    )
    list.try_each(object.functions, fn(f) {
      unique(list.map(f.arguments, fn(a) { a.name }))
    })
  })
}

fn unique(names: List(String)) -> Result(Nil, Error) {
  case list.length(list.unique(names)) == list.length(names) {
    True -> Ok(Nil)
    False ->
      Error(InvalidDefinition(
        "Duplicate object, field, function, or argument name",
      ))
  }
}

/// Build the module schema using the same codecs used by function dispatch.
pub fn register(
  client: types.Query,
  objects: List(Object),
) -> Result(json.Json, Error) {
  use _ <- result.try(validate(objects))
  let root = query.root(query.connection(client.selection))
  let selection =
    list.fold(objects, query.select(root, "module", []), fn(module, object) {
      let definition =
        query.select(root, "typeDef", [])
        |> query.select("withObject", [
          #("name", query.String(object.name)),
          #("description", query.String(object.description)),
        ])
      let definition =
        list.fold(object.fields, definition, fn(definition, field) {
          query.select(definition, "withField", [
            #("name", query.String(field.name)),
            #("typeDef", query.Reference(type_definition(root, field.schema))),
          ])
        })
      let definition =
        list.fold(object.functions, definition, fn(definition, function) {
          let field = case function.name {
            "" -> "withConstructor"
            _ -> "withFunction"
          }
          query.select(definition, field, [
            #("function", query.Reference(function_definition(root, function))),
          ])
        })
      query.select(module, "withObject", [
        #("object", query.Reference(definition)),
      ])
    })
  query.select(selection, "id", [])
  |> query.execute(decode.string)
  |> result.map(json.string)
  |> result.map_error(SdkError)
}

fn function_definition(
  root: query.Selection,
  function: Function,
) -> query.Selection {
  let selection =
    query.select(root, "function", [
      #("name", query.String(function.name)),
      #("returnType", query.Reference(type_definition(root, function.returns))),
    ])
    |> query.select("withDescription", [
      #("description", query.String(function.description)),
    ])
  list.fold(function.arguments, selection, fn(selection, arg) {
    let args = [
      #("name", query.String(arg.name)),
      #("typeDef", query.Reference(type_definition(root, arg.schema))),
      #("description", query.String(arg.description)),
    ]
    let args = case arg.default {
      None -> args
      Some(value) ->
        list.append(args, [
          #("defaultValue", query.String(json.to_string(value))),
        ])
    }
    query.select(selection, "withArg", args)
  })
}

fn type_definition(
  root: query.Selection,
  type_: codec.Type,
) -> query.Selection {
  let selection = query.select(root, "typeDef", [])
  case type_ {
    codec.OptionalType(inner) ->
      query.select(type_definition(root, inner), "withOptional", [
        #("optional", query.Boolean(True)),
      ])
    codec.ListType(inner) ->
      query.select(selection, "withListOf", [
        #("elementType", query.Reference(type_definition(root, inner))),
      ])
    codec.ObjectType(name) ->
      query.select(selection, "withObject", [#("name", query.String(name))])
    _ -> {
      let kind = case type_ {
        codec.StringType -> "STRING_KIND"
        codec.IntType -> "INTEGER_KIND"
        codec.FloatType -> "FLOAT_KIND"
        codec.BoolType -> "BOOLEAN_KIND"
        _ -> "VOID_KIND"
      }
      query.select(selection, "withKind", [#("kind", query.Enum(kind))])
    }
  }
}
