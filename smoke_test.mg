import server "server";
import mem "std/mem";
import fmt "std/fmt";

@main()
fn main() {
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

struct EchoClient {
  handle: *server::ClientHandle,
}

fn new_client(handle: *server::ClientHandle): *void {
  let client = mem::alloc::<EchoClient>();
  client.handle.* = handle;
  return client as *void;
}

fn free_client(c: *void) {
  let c = c as *EchoClient;
  mem::dealloc::<EchoClient>(c);
}

fn on_message(client: *void, msg: [*]u8, size: usize) {
  let client = client as *EchoClient;

  // fmt::print_str("message received: ");
  // let i: usize = 0;
  // while i < size {
  //   fmt::print_u8(msg[i].*);
  //   fmt::print_str(" ");
  //   i = i + 1;
  // }
  // fmt::print_str("\n");

  server::client_write(client.handle.*, msg, size);
}
