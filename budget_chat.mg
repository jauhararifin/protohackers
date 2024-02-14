import server "server";
import mem "std/mem";
import fmt "std/fmt";
import vec "std/vec";
import wasm "std/wasm";

let MAX_USERS: usize = 100;

let available_user_ids: *vec::Vector<usize> = mem::alloc::<vec::Vector<usize>>();
let clients:            [*]ChatClient       = mem::alloc_array::<ChatClient>(100);

@main()
fn main() {
  let i: usize = 0;
  while i < MAX_USERS {
    vec::push::<usize>(available_user_ids, i);
    i = i + 1;
  }

  let server_fd: i32 = 3;
  let s = server::new(server::Config{
    fd:          server_fd,
    new_client:  new_client,
    free_client: free_client,
    on_message:  on_message,
  });

  server::run(s);

  server::free(s);
}

struct ChatClient {
  handle: *server::ClientHandle,

  name: [*]u8,

  user_id: usize,
  buff:    [*]u8,
  len:     usize,
}

fn new_client(handle: *server::ClientHandle): *void {
  if vec::len::<usize>(available_user_ids) == 0 {
    fmt::print_str("maximum user reached!\n");
    wasm::trap();
  }
  let user_id = vec::pop::<usize>(available_user_ids);

  fmt::print_str("user connected ");
  fmt::print_usize(user_id);
  fmt::print_str("\n");

  let msg = "Welcome to budgetchat! What shall I call you?\n";
  server::client_write(handle, msg, fmt::strlen(msg));

  let client = clients[user_id];
  client.handle.* = handle;
  client.buff.* = mem::alloc_array::<u8>(4096);
  client.len.* = 0;
  client.user_id.* = user_id;
  client.name.* = 0 as [*]u8;

  return client as *void;
}

fn free_client(c: *void) {
  let client = c as *ChatClient;

  fmt::print_str("user disconnected ");
  fmt::print_usize(client.user_id.*);
  fmt::print_str("\n");

  if client.name.* as usize != 0 {
    let i: usize = 0;
    while i < MAX_USERS {
      if i != client.user_id.* && clients[i].name.* as usize != 0 {
        server::client_write(clients[i].handle.*, "* ", 2);
        server::client_write(clients[i].handle.*, client.name.*, fmt::strlen(client.name.*));
        let msg = " has leave the room\n";
        server::client_write(clients[i].handle.*, msg, fmt::strlen(msg));
      }
      i = i + 1;
    }
  }

  vec::push::<usize>(available_user_ids, client.user_id.*);

  mem::dealloc_array::<u8>(client.buff.*);
  if client.name.* as usize != 0 {
    mem::dealloc_array::<u8>(client.name.*);
  }
  client.name.* = 0 as [*]u8;
}

fn on_message(client: *void, msg: [*]u8, size: usize) {
  let client = client as *ChatClient;

  let i: usize = 0;
  while i < size {
    client.buff.*[client.len.*].* = msg[i].*;
    client.len.* = client.len.* + 1;

    if msg[i].* == '\n' {
      process_message(client);
      client.len.* = 0;
    }

    i = i + 1;
  }
}

fn process_message(client: *ChatClient) {
  if client.name.* as usize == 0 {
    process_login(client);
  } else {
    process_chat(client);
  }
}

fn process_login(client: *ChatClient) {
  if !is_valid_name(client) {
    fmt::print_str("invalid name!!!\n");
    let msg = "invalid name\n";
    server::client_write(client.handle.*, msg, fmt::strlen(msg));
    server::client_disconnect(client.handle.*);
    return;
  }

  let len = client.len.*;
  client.name.* = mem::alloc_array::<u8>(len);
  let i: usize = 0;
  while i < len-1 {
    client.name.*[i].* = client.buff.*[i].*;
    i = i + 1;
  }
  client.name.*[len-1].* = 0;

  let msg = "* The room contains: ";
  server::client_write(client.handle.*, msg, fmt::strlen(msg));
  let i: usize = 0;
  let is_first = true;
  while i < MAX_USERS {
    if i != client.user_id.* && clients[i].name.* as usize != 0 {
      if !is_first {
        let msg = ", ";
        server::client_write(client.handle.*, msg, fmt::strlen(msg));
      }
      is_first = false;

      let name = clients[i].name.*;
      server::client_write(client.handle.*, name, fmt::strlen(name));
    }
    i = i + 1;
  }
  let msg = "\n";
  server::client_write(client.handle.*, msg, fmt::strlen(msg));

  let i: usize = 0;
  while i < MAX_USERS {
    if i != client.user_id.* && clients[i].name.* as usize != 0 {
      server::client_write(clients[i].handle.*, "* ", 2);
      server::client_write(clients[i].handle.*, client.name.*, fmt::strlen(client.name.*));
      let msg = " has entered the room\n";
      server::client_write(clients[i].handle.*, msg, fmt::strlen(msg));
    }
    i = i + 1;
  }
}

fn process_chat(client: *ChatClient) {
  let i: usize = 0;
  while i < MAX_USERS {
    if i != client.user_id.* && clients[i].name.* as usize != 0 {
      server::client_write(clients[i].handle.*, "[", 1);
      server::client_write(clients[i].handle.*, client.name.*, fmt::strlen(client.name.*));
      server::client_write(clients[i].handle.*, "] ", 2);
      server::client_write(clients[i].handle.*, client.buff.*, client.len.*);
    }
    i = i + 1;
  }
}

fn is_valid_name(client: *ChatClient): bool {
  let i: usize = 0;
  let len = client.len.*;

  client.buff.*[len-1].* = 0;
  fmt::print_str("checking name: ");
  fmt::print_str(client.buff.*);
  fmt::print_str("\n");

  if len <= 1 {
    return false;
  }

  while i < len-1 {
    let c = client.buff.*[i].*;
    let valid = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
    if !valid {
      return false;
    }
    i = i + 1;
  }
  return true;
}
