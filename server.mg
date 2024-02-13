import wasi "std/wasi";
import mem "std/mem";
import fmt "std/fmt";

let DEBUG_ENABLED: bool = false;

let MAX_CLIENT: usize = 10;
let CLIENT_BUFF: usize = 16384; // 16KB

let ACCEPT_EVENT: u64 = 1;
let READ_EVENT:   u64 = 2;
let WRITE_EVENT:  u64 = 3;

struct Server {
  fd:             i32,
  subscriptions:  [*]wasi::Subscription,
  events:         [*]wasi::Event,
  n_subscription: usize,
  clients:        [*]ClientHandle,
  n_client:       usize,
  n_event:        usize,

  new_client:  fn( *ClientHandle): *void,
  free_client: fn( *void),
  on_message:  fn( *void, [*]u8, usize),
}

struct ClientHandle {
  fd:     i32,
  buff:   [*]u8,
  client: *void,
}

struct Config {
  fd: i32,

  new_client: fn( *ClientHandle): *void,
  free_client: fn( *void),
  on_message: fn( *void, [*]u8, usize),
}

fn new(config: Config): *Server {
  let server = mem::alloc::<Server>();

  server.subscriptions.* = mem::alloc_array::<wasi::Subscription>(1 + MAX_CLIENT * 2);
  server.events.* = mem::alloc_array::<wasi::Event>(1 + MAX_CLIENT * 2);
  server.fd.* = config.fd;

  server.new_client.* = config.new_client;
  server.free_client.* = config.free_client;
  server.on_message.* = config.on_message;

  server.subscriptions.*[0].* = wasi::Subscription{
    userdata: ACCEPT_EVENT,
    u:        wasi::SubscriptionU{
      tag:            wasi::EVENT_TYPE_FD_READ,
      clock_id_or_fd: config.fd,
    },
  };
  server.n_subscription.* = 1;

  server.clients.* = mem::alloc_array::<ClientHandle>(MAX_CLIENT);
  let i: usize = 0;
  while i < MAX_CLIENT {
    server.clients.*[i].* = ClientHandle{
      fd: 0,
      buff: mem::alloc_array::<u8>(CLIENT_BUFF),
    };
    i = i + 1;
  }
  server.n_client.* = 0;

  return server;
}

fn run(server: *Server) {
  fmt::print_str("start listening...\n");

  while true {
    let errcode = wasi::poll_oneoff(server.subscriptions.*, server.events.*, server.n_client.* + 1, server.n_event);
    abort_on_error("cannot poll events", errcode);

    let i: usize = 0;
    while i < server.n_event.* {
      debug_event(server.events.*[i]);
      abort_on_error("error in the event", server.events.*[i].errno.*);
      i = i + 1;
    }

    let i: usize = 0;
    while i < server.n_event.* {
      let userdata = server.events.*[i].userdata.*;
      let kind = userdata & 0xffffffff;
      if kind == ACCEPT_EVENT {
        handle_accept(server);
      } else if kind == READ_EVENT {
        handle_read(server, server.events.*[i]);
      } else if kind == WRITE_EVENT {
        // TODO
      }

      i = i + 1;
    }
  }
}

fn handle_accept(server: *Server) {
  if server.n_client.* >= MAX_CLIENT {
    fmt::print_str("maximum number of client exceeded, connection ignored\n");
    return;
  }

  let client_fd_ptr = mem::alloc::<i32>();

  while true {
    let errcode = wasi::sock_accept(server.fd.*, 0b100, client_fd_ptr);
    if errcode == wasi::ERROR_EAGAIN {
      break;
    }
    abort_on_error("cannot accept client", errcode);
    fmt::print_str("client connected!\n");

    let client_fd = client_fd_ptr.*;
    let client_id = server.n_client.*;
    server.n_client.* = server.n_client.* + 1;
    server.clients.*[client_id].fd.* = client_fd;

    let client = server.new_client.*(server.clients.*[client_id]);
    server.clients.*[client_id].client.* = client;

    server.subscriptions.*[client_id+1].* = wasi::Subscription{
      userdata: READ_EVENT | (client_id as u64 << 32),
      u:        wasi::SubscriptionU{
        tag:            wasi::EVENT_TYPE_FD_READ,
        clock_id_or_fd: client_fd,
      },
    };
  }

  mem::dealloc::<i32>(client_fd_ptr);
}

fn handle_read(server: *Server, event: *wasi::Event) {
  let client_id = ((event.userdata.* >> 32) & 0xffffffff) as usize;
  let client = server.clients.*[client_id];
  let fd = client.fd.*;

  let hungup = (event.fd_readwrite.flags.* & 1) != 0;
  if hungup {
    handle_hungup(server, client_id);
    return;
  }

  let iovec = mem::alloc_array::<wasi::IoVec>(1);
  let ro_count = mem::alloc::<usize>();
  let ro_flags = mem::alloc::<u16>();

  while true {
    iovec[0].* = wasi::IoVec{
      p:   client.buff.*,
      len: CLIENT_BUFF,
    }

    let errcode = wasi::sock_recv(fd, iovec, 1, 0, ro_count, ro_flags);
    if errcode == wasi::ERROR_EAGAIN {
      break;
    }
    abort_on_error("cannot read client", errcode);

    if ro_count.* == 0 {
      handle_hungup(server, client_id);
      break;
    } else {
      server.on_message.*(client.client.*, client.buff.*, ro_count.*);
    }
  }

  mem::dealloc::<u16>(ro_flags);
  mem::dealloc::<usize>(ro_count);
  mem::dealloc_array::<wasi::IoVec>(iovec);
}

fn handle_hungup(server: *Server, client_id: usize) {
  let client = server.clients.*[client_id];
  let fd = client.fd.*;
  server.free_client.*(client.client.*);

  let n_client = server.n_client.*;
  server.subscriptions.*[client_id+1].* = server.subscriptions.*[n_client].*;
  server.clients.*[client_id].* = server.clients.*[n_client-1].*;
  server.n_client.* = n_client - 1;

  let errcode = wasi::fd_close(fd);
  abort_on_error("cannot shutdown client", errcode);
  fmt::print_str("client disconnected!\n");
}

fn debug_event(event: *wasi::Event) {
  if DEBUG_ENABLED {
    fmt::print_str("> got event | ");
    fmt::print_str("type=");
    fmt::print_u8(event.type.*);
    fmt::print_str(", errno=");
    fmt::print_u16(event.errno.*);
    fmt::print_str(", nbytes=");
    fmt::print_u64(event.fd_readwrite.nbytes.*);
    fmt::print_str(", flags=");
    fmt::print_u16(event.fd_readwrite.flags.*);
    fmt::print_str(", userdata=");
    fmt::print_u64(event.userdata.*);
    fmt::print_str("\n");
  }
}

fn abort_on_error(msg: [*]u8, errno: u16) {
  if errno == 0 {
    return;
  }

  fmt::print_str(msg);
  fmt::print_str(", errorno: ");
  fmt::print_u16(errno);
  fmt::print_str("\n");

  wasi::proc_exit(1);
}

fn free(server: *Server) {
  mem::dealloc_array::<wasi::Subscription>(server.subscriptions.*);
  mem::dealloc_array::<wasi::Event>(server.events.*);
  mem::dealloc_array::<ClientHandle>(server.clients.*);
}

fn client_write(handle: *ClientHandle, buff: [*]u8, size: usize) {
  let iovec = mem::alloc_array::<wasi::IoVec>(1);
  let written: usize = 0;
  let n = mem::alloc::<usize>();

  while written < size {
    let p = (buff as usize + written) as [*]u8;
    iovec[0].* = wasi::IoVec{
      p:   p,
      len: size - written,
    };
    let errcode = wasi::sock_send(handle.fd.*, iovec, 1, 0, n);
    abort_on_error("cannot write to socket", errcode);

    if DEBUG_ENABLED {
      fmt::print_str("write: ");
      let i: usize = 0;
      while i < n.* {
        fmt::print_u8(p[i].*);
        fmt::print_str(" ");
        i = i + 1;
      }
      fmt::print_str("\n");
    }

    written = written + n.*;
  }
}
