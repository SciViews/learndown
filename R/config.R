#' Configure the R environment for the course (including database information)
#'
#' Call this function every time you need to get environment variables set, like
#' the URL, user and password of the MongoDB database used by the course.
#' @param url The URL of the encrypted file that contains the configuration
#' information.
#' @param password The password to decrypt the data.
#' @param cache The path to the file to use to store a cached version of these
#' data. Access to the database will be checked, and if it fails, the
#' configuration data are refreshed from the URL.
#' @param object An object to be encrypted.
#'
#' @return Invisibly returns `TRUE` if success, or `FALSE` otherwise for
#' [config()]. The encrypted/decrypted object for [encrypt()] and [decrypt()].
#' @export
config <- function(url, password, cache = ".learndown_config") {
  # Set environment variables according to entries in a crypted configuration
  # file, and return the crypted data, if it succeeds (test database access)
  setenv <- function(file, password) {
    try({
      conf_crypt <- readRDS(file)
      conf <- decrypt(conf_crypt, password = password)
      # Set environment variables
      for (item in names(conf)) {
        if (Sys.getenv(item) != "")
          conf[[item]] <- NULL # Do not replace this item if already there
      }
      if (length(conf))
        do.call(Sys.setenv, conf)

      # Test the access to the MongoDB database, using env. vars
      user <- Sys.getenv("MONGO_USER")
      password <- Sys.getenv("MONGO_PASSWORD")
      mongo_url <- glue(Sys.getenv("MONGO_URL"))
      db <- Sys.getenv("MONGO_BASE")
      mongo(collection = "learnr", db = db, url = mongo_url)
      # Return conf_crypt
      conf_crypt
    }, silent = TRUE)
  }

  # If the cache file is there, use it
  if (file.exists(cache)) {
    res <- setenv(cache, password = password)
    if (!inherits(res, "try-error")) {
      message("Learndown configuration set from cache")
      return(invisible(TRUE))
    }
  }

  # If no file cache, or an error occurs, try getting the config file from url
  res <- setenv(url(url), password = password)
  if (inherits(res, "try-error")) {
    message("Incorrect configuration or database not responding: ", res)
    return(invisible(FALSE))
  } else {
    message("Learndown configuration set from URL")
    # Save these data into the cache file
    try(suppressWarnings(saveRDS(res, file = cache)), silent = TRUE)
    return(invisible(TRUE))
  }
}

#' @rdname config
#' @export
encrypt <- function(object, password) {
  password <- as.character(password)
  if (length(password) != 1)
    stop("Use a single character string for the password")
  if (!nchar(password))
    stop("The password cannot be empty")

  # Create a secure key from the password
  key <- PKI.digest(charToRaw(password), "SHA256")

  # Encrypt object
  serialize <- textConnection("serialized", "w")
  dput(object, file = serialize, control = "all")
  close(serialize)
  serialized <- charToRaw(paste(serialized, collapse = "\n"))
  PKI.encrypt(serialized, key, "aes256")
}

#' @rdname config
#' @export
decrypt <- function(object, password) {
  password <- as.character(password)
  if (length(password) != 1)
    stop("Use a single character string for the password")
  if (!nchar(password))
    stop("The password cannot be empty")

  # Create a secure key from the password
  key <- PKI.digest(charToRaw(password), "SHA256")

  # Decrypt and deserialize the object
  serialized <- PKI.decrypt(object, key, "aes256")
  serialized <- rawToChar(serialized)
  dget(textConnection(serialized))
}