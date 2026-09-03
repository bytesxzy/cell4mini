{ pkgs }: {
  deps = [
    pkgs.luajit      # the interpreter this build targets
    pkgs.curl        # rsi/kernel/research.lua shells out to curl for arXiv + ARC
    pkgs.coreutils   # mkdir / rm / ls, used for the lock directory and snapshots
  ];
}
