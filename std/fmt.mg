import wasi "std/wasi";
import mem "std/mem";

fn print_str(p: [*]u8) {
  let len = strlen(p);
  let iovec = mem::alloc::<wasi::IoVec>();
  iovec.* = wasi::IoVec{
    len: len,
    p:   p,
  };

  wasi::fd_write(1, iovec, 1, 0 as *i32);
  mem::dealloc::<wasi::IoVec>(iovec);
}

fn strlen(p: [*]u8): usize {
  let i: usize = 0;
  while p[i].* != 0 {
    i = i + 1;
  }
  return i;
}

fn print_bool(val: bool) {
  if val {
    print_str("true");
  } else {
    print_str("false");
  }
}

fn print_char(val: u8) {
  let p = mem::alloc_array::<u8>(1);
  p[0].* = val;

  let iovec = mem::alloc::<wasi::IoVec>();
  iovec.* = wasi::IoVec{
    len: 1,
    p:   p,
  };

  wasi::fd_write(1, iovec, 1, 0 as *i32);

  mem::dealloc_array::<u8>(p);
  mem::dealloc::<wasi::IoVec>(iovec);
}

fn print_i8(val: i8) { print_i64(val as i64); }
fn print_i16(val: i16) { print_i64(val as i64); }
fn print_i32(val: i32) { print_i64(val as i64); }
fn print_isize(val: isize) { print_i64(val as i64); }

fn print_u8(val: u8) { print_u64(val as u64); }
fn print_u16(val: u16) { print_u64(val as u64); }
fn print_u32(val: u32) { print_u64(val as u64); }
fn print_usize(val: usize) { print_u64(val as u64); }

fn print_i64(val: i64) {
  if val == 0 {
    print_str("0");
    return;
  }

  let str = mem::alloc_array::<u8>(10);
  let str_n: usize = 0;

  let start: usize = 0;
  if val < 0 {
    str[str_n].* = 45; // ascii for '-'
    str_n = str_n + 1;
    start = 1;
  }

  while val != 0 {
    let d = val % 10;
    if d < 0 {
      d = -d;
    }
    str[str_n].* = 48 + d as u8; // 48 is ascii for '0'
    str_n = str_n + 1;
    val = val / 10;
  }

  let i: usize = start;
  let j = str_n - 1;
  while i < j {
    let tmp = str[i].*;
    str[i].* = str[j].*;
    str[j].* = tmp;
    i = i + 1;
    j = j - 1;
  }

  str[str_n].* = 0;
  str_n = str_n + 1;
  print_str(str);
  mem::dealloc_array::<u8>(str);
}

fn print_u64(val: u64) {
  if val == 0 {
    print_str("0");
    return;
  }

  let str = mem::alloc_array::<u8>(10);
  let str_n: usize = 0;

  while val != 0 {
    let d = val % 16;
    if d > 9 {
      str[str_n].* = 97 + (d as u8) - 10; // ascii for 'a'
    } else {
      str[str_n].* = 48 + (d as u8); // ascii for '0'
    }
    str_n = str_n + 1;
    val = val / 16;
  }

  let i: usize = 0;
  let j = str_n - 1;
  while i < j {
    let tmp = str[i].*;
    str[i].* = str[j].*;
    str[j].* = tmp;
    i = i + 1;
    j = j - 1;
  }

  str[str_n].* = 0;
  str_n = str_n + 1;
  print_str("0x");
  print_str(str);
  mem::dealloc_array::<u8>(str);
}
