 
To compile:

```bash
magelang compile smoke_test -o smoke_test.wasm
```

To run:

```
wasmtime -S tcplisten=0.0.0.0:5100,preview2=n --optimize opt-level=2,smoke_test.wasm
```
