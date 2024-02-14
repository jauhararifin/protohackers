import mem "std/mem";
import wasm "std/wasm";

struct Vector<T> {
  arr: [*]T,
  cap: usize,
  len: usize,
}

fn new<T>(): Vector<T> {
  return Vector::<T>{
    cap: 0,
    len: 0,
    arr: 0 as [*]T,
  };
}

fn new_with_cap<T>(cap: usize): Vector<T> {
  let arr = mem::alloc_array::<T>(cap);
  return Vector::<T>{
    cap: cap,
    len: 0,
    arr: arr,
  };
}

fn push<T>(vec: *Vector<T>, item: T) {
  if vec.len.* == vec.cap.* {
    let new_cap: usize = 1;
    let should_delete_old_array = false;
    if vec.cap.* != 0 {
      new_cap = vec.cap.* * 2;
      should_delete_old_array = true;
    }

    let arr = mem::alloc_array::<T>(new_cap);
    let i: usize = 0;
    while i < vec.len.* {
      arr[i].* = vec.arr.*[i].*;
      i = i + 1;
    }

    if should_delete_old_array {
      mem::dealloc_array::<T>(vec.arr.*);
    }

    vec.cap.* = new_cap;
    vec.arr.* = arr;
  }

  vec.arr.*[vec.len.*].* = item;
  vec.len.* = vec.len.* + 1;
}

fn pop<T>(vec: *Vector<T>): T {
  if vec.len.* == 0 {
    wasm::trap();
  }

  vec.len.* = vec.len.* - 1;
  return vec.arr.*[vec.len.*].*;
}

fn set<T>(vec: *Vector<T>, i: usize, val: T) {
  vec.arr.*[i].* = val;
}

fn get<T>(vec: *Vector<T>, i: usize): T {
  return vec.arr.*[i].*;
}

fn len<T>(vec: *Vector<T>): usize {
  return vec.len.*;
}


