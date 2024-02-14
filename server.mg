import wasi "std/wasi";
import mem "std/mem";
import fmt "std/fmt";

let DEBUG_ENABLED: bool = true;

let MAX_CLIENT: usize = 10;
let CLIENT_BUFF: usize = 16384; // 16KB

let ACCEPT_EVENT: u64 = 1;
let READ_EVENT:   u64 = 2;
let WRITE_EVENT:  u64 = 3;

struct Server {
  fd:             i32,
  subscriptions:  [*]wasi::Subscription,
  events:         [*]wasi::Event,
  clients:        [*]ClientHandle,
  n_client:       usize,
  n_event:        usize,

  new_client:  fn( *ClientHandle): *void,
  free_client: fn( *void),
  on_message:  fn( *void, [*]u8, usize),
}

struct ClientHandle {
  server:        *Server,
  disconnecting: bool,

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

  server.clients.* = mem::alloc_array::<ClientHandle>(MAX_CLIENT);
  let i: usize = 0;
  while i < MAX_CLIENT {
    server.clients.*[i].* = ClientHandle{
      server:        server,
      disconnecting: false,

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
    fmt::print_str("start polling\n");

    let i: usize = 0;
    while i < server.n_client.* {
      server.subscriptions.*[i+1].* = wasi::Subscription{
        userdata: READ_EVENT | (i as u64 << 32),
        u:        wasi::SubscriptionU{
          tag:            wasi::EVENT_TYPE_FD_READ,
          clock_id_or_fd: server.clients.*[i].fd.*,
        },
      };
      i = i + 1;
    }

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
        // TODO: fix this! handle_read might reorder the clients index, and thus messing with the event index
        handle_read(server, server.events.*[i]);
      } else if kind == WRITE_EVENT {
        // TODO
      }

      i = i + 1;
    }

    // remove disconnected clients
    let i: usize = 0;
    let removed: usize = 0;
    while i < server.n_client.* {
      if server.clients.*[i].fd.* == 0 {
        removed = removed + 1;
      } else if removed > 0 {
        server.clients.*[i-removed].* = server.clients.*[i].*;
      }
      i = i + 1;
    }
    server.n_client.* = server.n_client.* - removed;
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
    abort_on_sock_error(server.fd.*, "cannot accept client", errcode);

    fmt::print_str("client fd=");
    fmt::print_i32(client_fd_ptr.*);
    fmt::print_str(" is connected!\n");

    let client_fd = client_fd_ptr.*;
    let client_id = server.n_client.*;
    server.n_client.* = server.n_client.* + 1;
    server.clients.*[client_id].fd.* = client_fd;
    server.clients.*[client_id].disconnecting.* = false;

    let client = server.new_client.*(server.clients.*[client_id]);
    server.clients.*[client_id].client.* = client;
  }

  mem::dealloc::<i32>(client_fd_ptr);
}

fn handle_read(server: *Server, event: *wasi::Event) {
  let client_id = ((event.userdata.* >> 32) & 0xffffffff) as usize;
  let client = server.clients.*[client_id];
  let fd = client.fd.*;

  if fd == 0 {
    fmt::print_str("skip reading the client since fd == 0\n");
    return;
  }

  let hungup = (event.fd_readwrite.flags.* & 1) != 0;
  if client.disconnecting.* || hungup {
    fmt::print_str("client is disconnecting, or hangup flag is on");
    fmt::print_i32(fd);
    fmt::print_str("\n");

    handle_hungup(server, client_id);
    return;
  }

  let iovec = mem::alloc_array::<wasi::IoVec>(1);
  let ro_count = mem::alloc::<usize>();
  let ro_flags = mem::alloc::<u16>();

  while true {
    if client.disconnecting.* {
      fmt::print_str("client is disconnecting");
      fmt::print_i32(fd);
      fmt::print_str("\n");
      handle_hungup(server, client_id);
      break;
    }

    iovec[0].* = wasi::IoVec{
      p:   client.buff.*,
      len: CLIENT_BUFF,
    }

    let errcode = wasi::sock_recv(fd, iovec, 1, 0, ro_count, ro_flags);
    if errcode == wasi::ERROR_EAGAIN {
      break;
    }
    abort_on_sock_error(fd, "cannot read client", errcode);

    if ro_count.* == 0 {
      fmt::print_str("ro count is 0, hungup ");
      fmt::print_i32(fd);
      fmt::print_str("\n");

      handle_hungup(server, client_id);
      break;
    } else {
      if DEBUG_ENABLED {
        fmt::print_str("read, fd: ");
        fmt::print_i32(fd);
        fmt::print_str(", msg: ");

        let i: usize = 0;
        while i < ro_count.* {
          let c = client.buff.*[i].*;
          fmt::print_char(c);
          i = i + 1;
        }
        fmt::print_str("\n");
      }

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
  client.fd.* = 0;
  server.free_client.*(client.client.*);

  fmt::print_str("shutdown and close: ");
  fmt::print_i32(fd);
  fmt::print_str("\n");

  wasi::sock_shutdown(fd, 0b11);
  wasi::fd_close(fd);

  fmt::print_str("client disconnected! ");
  fmt::print_i32(fd);
  fmt::print_str("\n");
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

fn abort_on_sock_error(fd: i32, msg: [*]u8, errno: u16) {
  if errno == 0 {
    return;
  }

  fmt::print_str(msg);
  fmt::print_str(", fd: ");
  fmt::print_i32(fd);
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
  if handle.fd.* == 0 {
    return;
  }

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
    abort_on_sock_error(handle.fd.*, "cannot write to socket", errcode);

    if DEBUG_ENABLED {
      fmt::print_str("write, fd: ");
      fmt::print_i32(handle.fd.*);
      fmt::print_str(", msg: ");

      let i: usize = 0;
      while i < n.* {
        let c = p[i].*;
        fmt::print_char(c);
        i = i + 1;
      }
      fmt::print_str("\n");
    }

    written = written + n.*;
  }
}

fn client_disconnect(handle: *ClientHandle) {
  handle.disconnecting.* = true;

  fmt::print_str("shutdown and close: ");
  fmt::print_i32(handle.fd.*);
  fmt::print_str("\n");

  wasi::sock_shutdown(handle.fd.*, 0b11);
  wasi::fd_close(handle.fd.*);
}
