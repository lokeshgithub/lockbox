.lockbox_env <- new.env(parent = emptyenv())

set_session_id <- function() {
  if (isTRUE(getOption("lockbox.disable_sessions"))) {
    return()
  }

  if (is.null(.lockbox_env$session_id)) {
    ## This is our first run, so we want to register the finalizer to drop our temp directories
    reg.finalizer(.lockbox_env, function(env) {
      lapply(
        lockbox_session_dirs(), 
          function(path) {  try(unlink(x, recursive = TRUE, force = TRUE), silent = TRUE) }
        )
    }, onexit = TRUE)  
  }
  
  if (requireNamespace("uuid", quietly = TRUE)) {
    .lockbox_env$session_id <- .lockbox_env$session_id %||% uuid::UUIDgenerate()
  } else {
    .lockbox_env$session_id <- .lockbox_env$session_id %||% digest::digest(as.integer(Sys.time()))
  }
}

set_transient_library <- function() {
  if (!is.null(.lockbox_env$old_dir)) return()

  dir <- lockbox_transient_dir()
  if (!file.exists(dir)) dir.create(dir, FALSE, TRUE)
  .lockbox_env$old_dir <- .libPaths()

  # We add one final library path: a transient staging library
  # that is used to copy over installed packages to the vanilla
  # library.
  transient_staging_path <- lockbox_transient_staging_dir()
  if (!file.exists(transient_staging_path)) {
    unlink(transient_staging_path, TRUE, TRUE)
    dir.create(transient_staging_path, FALSE, TRUE)
  }
  .libPaths(c(transient_staging_path, dir, .libPaths()))

  # Finally, we initialize the transient library with some sane default symlinks.
  with_real_packages(lockbox_library(), function(pkgpath) {
    versions <- list.files(pkgpath)
    versions <- grep("^[0-9.]+$", versions, value = TRUE)
    if (length(versions) == 0) { return() }
    src <- file.path(pkgpath, max(as.package_version(versions), na.rm = TRUE), basename(pkgpath))
    symlink(src, file.path(dir, basename(pkgpath)), force = TRUE)
  })
}

set_default_mirror <- function() {
  # Set default CRAN mirror to Rstudio's unless the user requests not to.
  if (is.null(getOption("lockbox.disable_default_mirror"))) {
    if (is.null(getOption("repos"))) {
      .lockbox_env$old_opts <- 
        options(repos = structure(c(CRAN = "http://cran.rstudio.com/")))
    }
  }
}

# If a parent directory has a lockfile.yml, load it when the package is attached.
load_project <- function(path = getwd()) {
  has_lockfile <- function(path) {
    file.exists(file.path(path, "lockfile.yml"))
  }

  is_root <- function(path) {
    identical(path, dirname(path))
  }

  path <- normalizePath(path, mustWork = FALSE)
  while (!has_lockfile(path) && !is_root(path)) {
    path <- dirname(path)
  }

  if (!is_root(path)) {
    lockbox(file.path(path, 'lockfile.yml'))
  } else if (!is.null(getOption("lockbox.default"))) {
    lockbox(getOption("lockbox.default"))
  }
}

# Move non-symlinks from transient library to real library in case
# user installs packages while using lockbox. See the addTaskCallback
# in .onLoad
sanitize_transient_library <- function(...) {
  transient_staging_lib <- lockbox_transient_staging_dir()
  # Exclude the lockbox transient library and transient staging library.
  lib <- setdiff(.libPaths(), c(libPath(), transient_staging_lib))[1L] 

  pkg_moved <- character(0)
  with_real_packages(transient_staging_lib, function(pkgpath) {
    pkgname   <- basename(pkgpath)                   
    pkg_moved <<- c(pkg_moved, pkgname)
    newpkg    <- file.path(lib, pkgname)

    unlink(newpkg, TRUE, TRUE)
    file.rename(pkgpath, newpkg)
  })

  if (length(pkg_moved)) {
    warning("You just installed the following packages while using lockbox:\n\n",
            paste(paste("-", pkg_moved), collapse = "\n"),
            "\n\nThese have been moved from ", sQuote(transient_staging_lib),
            " to ", sQuote(lib), ". In general, you should only install ",
            "packages in an R session that does not use lockbox, e.g., ",
            "by calling ", sQuote("R --vanilla"), " in the terminal.",
            call. = FALSE)
  }

  TRUE
}

.onLoad <- function(pkg, libPath) {
  set_session_id()
  set_transient_library()
  addTaskCallback(sanitize_transient_library, "lockbox_callback")
}

.onAttach <- function(pkg, libPath) {
  if (isTRUE(getOption("lockbox.autoload", TRUE))) { 
    load_project()
  }
}

.onUnLoad <- function(pkg) {
  .libPaths(.lockbox_env$old_dir)
  removeTaskCallback("lockbox_callback")

  if (exists("old_opts", envir = .lockbox_env, inherits = FALSE)) {
    options(.lockbox_env$old_opts)
  }
}


