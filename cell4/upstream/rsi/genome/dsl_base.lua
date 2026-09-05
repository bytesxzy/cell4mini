-- visible primitive selection (mutable)
return {
  ops = {
    -- list
    "reverse", "sort", "sort_desc", "head", "last", "tail", "init", "len", "sum", "max", "min",
    "map_add", "map_sub", "map_mul", "map_mod", "filter_even", "filter_odd", "filter_gt", "filter_lt",
    "take", "drop", "rotate", "concat", "dedup", "cumsum", "diffs", "count", "index_of", "range",
    "singleton", "nth", "abs_all", "mirror", "repeat_list", "zip_add", "evens_idx", "odds_idx",
    "push_front", "push_back", "product", "unique_count",
    -- int
    "add", "sub", "mul", "div", "mod", "max2", "min2", "sq", "inc", "dec", "double", "half", "abs", "neg",
    "is_even", "gt", "eq", "if_int",
    -- grid
    "flip_h", "flip_v", "transpose", "rot90", "rot180", "rot270", "height", "width", "hcat", "vcat",
    "mirror_h", "mirror_v", "upscale", "downscale", "recolor", "fill_nonzero", "count_color", "most_color",
    "most_nonzero_color", "least_nonzero_color", "crop_bbox", "gravity_down", "gravity_up", "gravity_left",
    "gravity_right", "shift_down", "shift_right", "add_border", "remove_border", "top_half", "bottom_half",
    "left_half", "right_half", "overlay", "flatten", "row", "col", "from_row", "nonzero_count", "const_grid",
    "invert_mask", "tile2x2", "object_count", "keep_largest", "keep_smallest", "largest_object_size",
  },
}
