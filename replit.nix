{ pkgs }: {
  deps = [
    pkgs.lua5_4
    pkgs.curl        # the research fetcher shells out to curl for arXiv and ARC
    pkgs.python3     # only for `python3 -m http.server` to view the console
  ];
}
