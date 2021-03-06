# ---- Install missing dependencies ----

packages <- c("vec2dtransf")
if (length(setdiff(packages, rownames(installed.packages()))) > 0) {
  install.packages(setdiff(packages, rownames(installed.packages())))
}

# ---- Load functions ----

#' Extract XY Vertices from SVG Paths
#' 
#' Currently only supports path, polyline, and line.
#' 
#' @param paths List of paths in the format returned by \code{xml2::as_list(svg_xml)}.
svg_paths_to_xy <- function(paths) {
  path_types <- names(paths)
  xy <- lapply(seq_along(paths), function(i_path) {
    xy_vector <- switch(path_types[i_path],
      path = svg_pathd_to_xy(attr(paths[[i_path]], "d")),
      polyline = strsplit(attr(paths[[i_path]], "points"), "[,\\s]+", perl = TRUE),
      line = c(attr(paths[[i_path]], "x1"), attr(paths[[i_path]], "y1"), attr(paths[[i_path]], "x2"), attr(paths[[i_path]], "y2"))
    )
    xy_matrix <- if (is.matrix(xy_vector)) xy_vector else matrix(as.numeric(unlist(xy_vector)), ncol = 2, byrow = TRUE)
  })
  path_ids <- sapply(paths, attr, "id")
  names(xy)[!sapply(path_ids, is.null)] <- path_ids[!sapply(path_ids, is.null)]
  return(xy)
}

#' Extract XY Vertices from SVG Path "d" String
#' 
#' Calculates the absolute coordinates of the vertices in an SVG path "d" string. Curvature is discarded. See \url{http://www.w3.org/TR/SVG/paths.html}.
#' NOTE: Not all possible commands are yet supported.
#' 
#' @param d SVG path "d" string.
#' @examples
#' svg_pathd_to_xy("M0,0")
#' svg_pathd_to_xy("M512.49414,580.41797c0,0,0.46777-0.15527,0.59277-0.18652s0.81152-0.24902,0.81152-0.24902l1.03027-0.3125")
svg_pathd_to_xy <- function(d) {
  # Prepare d string components
  d <- gsub("\\s", "", d)
  parts <- stringr::str_extract_all(d, "([a-zA-Z]{1}[^a-zA-Z]+)")
  commands <- unlist(lapply(parts, substr, 1, 1))
  param_strings <- unlist(lapply(parts, function(part) { substr(part, 2, nchar(part)) }))
  parameters <- lapply(strsplit(gsub("([0-9]{1})-", "\\1,-", param_strings), ","), as.numeric)
  xy <- matrix(NA, nrow = length(commands), ncol = 2)
  # Extract path vertices
  for (i in seq_along(commands)) {
    xy[i, ] <- switch(commands[i],
      # Path always begins with M (move to)
      M = if (i == 1) parameters[[i]] else stop(paste("Found M at position:", i)),
      # L/l (line to)
      L = parameters[[i]],
      l = xy[i - 1, ] + parameters[[i]],
      # H/h (horizontal line to)
      H = c(parameters[[i]], xy[i - 1, 2]),
      h = c(xy[i - 1, 1] + parameters[[i]], xy[i - 1, 2]),
      # V/v (vertical line to)
      V = c(xy[i - 1, 1], parameters[[i]]),
      v = c(xy[i - 1, 1], xy[i - 1, 2] + parameters[[i]]),
      # C/c (curve to)
      C = parameters[[i]][5:6],
      c = xy[i - 1, ] + parameters[[i]][5:6],
      # S/s (simple curve to)
      S = parameters[[i]][3:4],
      s = xy[i - 1, ] + parameters[[i]][3:4],
      # Z/z (close path)
      Z = xy[1, ],
      z = xy[1, ]
    )
  }
  # Return result
  return(xy)
}

#' Apply Transformation to 2D Points
#' 
#' An alternative to \code{\link{vec2dtransf::applyTransformation}}, which requires the \code{\link{sp}} package and does not play well with \code{*apply} functions.
#' 
#' @param xy Table of x and y coordinates [x1 y1; x2 y2; ...].
#' @param transform Transformation returned by either \code{\link{vec2dtransf::AffineTransformation}} or \code{\link{vec2dtransf::SimilarityTransformation}}.
apply_transformation <- function(xy, transform) {
  vec2dtransf::calculateParameters(transform)
  params <- vec2dtransf::getParameters(transform)
  # Similarity transformation
  if (length(params) == 4) {
    x <- params[1] * xy[, 1] + params[2] * xy[, 2] + params[3]
    y <- params[1] * xy[, 2] - params[2] * xy[, 1] + params[4]
  }
  # Affine transformation
  if (length(params) == 6) {
    x <- params[1] * xy[, 1] + params[2] * xy[, 2] + params[3]
    y <- params[4] * xy[, 1] + params[5] * xy[, 2] + params[6]
  }
  # Return result
  return(cbind(x, y))
}

# ---- Load SVG ----

filename <- "sources/krimmel-vaughn-1987-figure-8.svg"
xml <- xml2::read_html(filename)
svg <- xml2::as_list(xml)$body$svg

# ---- Convert SVG Paths to Axes Coordinates ----

results <- list()
for (i_group in seq_along(svg)) {
  # For each parent layer...
  group <- attr(svg[[i_group]], "id")
  if (!is.null(group) && group != "figure") {
    layers <- list()
    # For each child layer...
    for (i_layer in seq_along(svg[[i_group]])) {
      layer <- attr(svg[[i_group]][[i_layer]], "id")
      # Extract image coordinates of paths
      if (!is.null(layer)) {
        temp <- svg[[i_group]][[i_layer]]
        paths <- temp[names(temp) != ""]
        layers[[layer]] <- svg_paths_to_xy(paths)
      }
    }
    # Compute coordinate transformation
    # (format: 'x'[\\-0-9\\.]+'y'[\\-0-9\\.]+)
    fig_x <- as.numeric(gsub(".*x([\\-0-9\\.]+).*", "\\1", names(layers$axes), perl = TRUE))
    fig_y <- as.numeric(gsub(".*y([\\-0-9\\.]+).*", "\\1", names(layers$axes), perl = TRUE))
    img_xy <- do.call("rbind", layers$axes)
    if (nrow(img_xy) > 2) {
      transform <- vec2dtransf::AffineTransformation(data.frame(img_xy, fig_x, fig_y))  
    } else {
      transform <- vec2dtransf::SimilarityTransformation(data.frame(img_xy, fig_x, fig_y))  
    }
    # Apply transformation
    newdata <- lapply(layers$data, apply_transformation, transform)
    # Save results
    results[[group]] <- newdata
  }
}

# ---- Plot Results ----

n_groups <- length(results)
par(mfrow = c(n_groups, 1))
for (i_group in seq_along(results)) {
  xy <- do.call("rbind", results[[i_group]])
  for (i in seq_along(results[[i_group]])) {
    if (i == 1) {
      plot(results[[i_group]][[i]], type = "l", xlim = range(xy[, 1]), ylim = range(xy[, 2]), xlab = "", ylab = "")
      title(names(results)[i_group])
    } else {
      if (nrow(results[[i_group]][[i]]) > 1) {
        lines(results[[i_group]][[i]])  
      } else {
        points(results[[i_group]][[i]], pch = 20, cex = 0.2)  
      }
    }
  }
}

# ---- Check Time Zone ----

# https://www.timeanddate.com/time/zone/usa/valdez?year=1986
utc_local <- 9 # hours (AKST)
origin <- as.POSIXct("1985-12-31 00:00:00", format = "%Y-%m-%d %H:%M:%S", tz = "UTC")

# Valdez tide data (UTC reference)
valdez <- read.csv("https://raw.githubusercontent.com/ezwelty/cg-data/master/noaa-coops/data/valdez.csv", stringsAsFactors = FALSE)
valdez$t <- as.POSIXct(valdez$t, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

# Valdez tide data (figure)
figure <- as.data.frame(do.call("rbind", results$tide))
figure[, 1] <- as.POSIXct(figure[, 1] * 24 * 60 * 60 + utc_local * 60 * 60, origin = origin, tz = "UTC")

# Plot together
ind <- valdez$t >= min(figure[, 1]) & valdez$t <= max(figure[, 1])
plot(valdez$t[ind], valdez$hourly_height[ind], type = "l", col = 'black')
lines(figure[, 1], figure[, 2], col = 'red')

# ---- Format and save results ----

is_saved <- !names(results) %in% "tide"
for (i in which(is_saved)) {
  sequences <- lapply(seq_along(results[[i]]), function(j) {
    cbind(results[[i]][[j]], j)
  })
  df <- as.data.frame(do.call("rbind", sequences))
  names(df) <- c("t", "value", "sequence")
  df <- df[order(df$t), ]
  df$t <- format(as.POSIXct(df$t * 24 * 60 * 60 + utc_local * 60 * 60, origin = origin, tz = "UTC"), "%Y-%m-%dT%H:%M:%SZ")
  if (names(results)[i] == "precipitation") {
    notes <- names(results[[i]])
    notes[notes == "NULL"] <- NA
    notes <- gsub("_x7E_", "~", notes)
    notes <- gsub("_", " ", notes)
    df <- data.frame(t_begin = df$t[seq(1, nrow(df), 2)], t_end = df$t[seq(2, nrow(df), 2)], notes = notes)
  }
  write.csv(df, file.path("data", paste0(names(results)[i], ".csv")), na = "", row.names = FALSE, quote = FALSE)
}

# ---- Station metadata ----

# Estimated from point "H" in Figure 1
df <- data.frame(lat = 60.988913, lng = -147.035686) # WGS84 decimal degrees
write.csv(df, file.path("data", "station.csv"), na = "", row.names = FALSE, quote = FALSE)