#' Read shinylogs log data and format them in a data.frame
#'
#' Learndown Shiny applications are a special king of Shiny applications that log
#' events and check results. It uses the `shinylogs` package to log Shiny events
#' and [read_shinylogs()] reads such logs and convert their data into a format
#' that is suitable to include, say in a MongoDB database.
#'
#' @param file The path to the RDS file that contains the shinylogs log data.
#' @param version The version of the Shiny application. Version is not recorded
#' by shinylogs, so, we must provide it here.
#' @param log.errors Do we record errors too?
#' @param log.outputs Do we record outputs too (note that results are recorded
#' with inputs)?
#'
#' @return A data frame with the different events logged (one per line).
#' @export
#'
#' @seealso [record_shiny()], [trackEvents()]
#'
#' @examples
#' # TODO...
read_shinylogs <- function(file, version = "0",
  log.errors = TRUE, log.outputs = FALSE) {

  if (!grepl("\\.rds$", file))
    stop("read only rds shinylogs file")

  if (!file.exists(file))
    stop("file not found")

  logs <- read_rds_logs(file)

  # Initialize the data.frame with start and stop events
  session <- logs[["session"]]
  user_data <- try(fromJSON(session$user), silent = TRUE)
  if (inherits(user_data, "try-error"))
    user_data <- list(user = "", login = "", iemail = "")
  user <- user_data$user
  if (is.null(user) || !length(user) || user == "")
    user <- Sys.info()['user']
  if (is.null(user) || !length(user))
    user <- ""
  if (is.null(user_data$login) || !length(user_data$login))
    user_data$login <- ""
  if (is.null(user_data$iemail) || !length(user_data$iemail))
    user_data$iemail <- ""

  common_data <- list(
    tutorial = paste0("shiny_", session$app),
    version = as.character(version),
    user = as.character(user),
    login = user_data$login,
    email = tolower(user_data$iemail)
  )

  events <- data.frame(
    sessionid = c(session$sessionid, session$sessionid),
    name = c("", ""),
    timestamp = c(session$server_connected, session$server_disconnected),
    value = c(session$user, ""), # Complete user info only in the start event
    type = c("session.id", "session.id"),
    binding = c("", ""),
    state = c("start", "stop"),
    stringsAsFactors = FALSE)

  # Inputs
  if (length(logs$inputs)) {
    inputs <- logs[["inputs"]]
    inputs$state <- "inputs"
    inputs$value <-  as.character(inputs$value)
    events <- rbind(events, inputs)
  }

  # Errors
  if (isTRUE(log.errors) && length(logs$errors)) {
    errors <- logs[["errors"]]
    errors$value <- as.character(errors$error)
    errors$error <- NULL
    errors$type <- "text"
    errors$binding <- ""
    errors$state <- "errors"
    events <- rbind(events, errors)
  }

  # Outputs
  if (isTRUE(log.outputs) && length(logs$outputs)) {
    outputs <- logs[["outputs"]]
    outputs$value <- as.character(outputs$value)
    outputs$state <- "outputs"
    outputs$type <- ""
    outputs <- outputs[, c("sessionid", "name", "timestamp", "value", "type",
      "binding", "state")]
    events <- rbind(events, outputs)
  }

  # Now we combine common_data and events into a data.frame similar to what
  # we got from learnr applications
  res <- data.frame(
    session  = events$sessionid,
    date     = events$timestamp,
    tutorial = common_data$tutorial,
    version  = common_data$version,
    user     = common_data$user,
    login    = common_data$login,
    email    = common_data$email,
    label    = events$name,
    correct  = "", # We will rework this for results later on
    event    = events$state,
    data     = paste0('{"type":"', events$type, '","binding":"',
      events$binding, '"}'),
    value    = events$value,
    stringsAsFactors = FALSE)

  # Rework quit events
  is_quit <- res$label == "quit"
  if (any(is_quit)) {
    res$event[is_quit] <- "quit"
    res$label[is_quit] <- ""
  }

  # Rework result events
  is_result <- res$label == "learndown_result_"
  if (any(is_result)) {
    res$event[is_result] <- "result"
    res$label[is_result] <- ""
    results <- res$value[is_result]
    # We strip correct (TRUE/FALSE) out and put it in the correct column
    values <- character(0)
    correct <- character(0)
    for (i in 1:length(results)) {
      # We want to protect here again st wrong entries!
      value <- try(fromJSON(results[i]), silent = TRUE)
      if (inherits(value, "try-error")) {
        correct[i] <- "NA"
        values[i] <- results[i]
      } else {
        correct[i] <- as.character(value$correct)
        value$correct <- NULL
        values[i] <- as.character(toJSON(value, auto_unbox = TRUE))
      }
    }
    res$correct[is_result] <- correct
    res$value[is_result] <- values
  } else {
    # We want at least one result, so, we add one with correct == "NA" now
    fake_result <- data.frame(
      session  = session$sessionid,
      date     = session$server_disconnected,
      tutorial = common_data$tutorial,
      version  = common_data$version,
      user     = common_data$user,
      login    = common_data$login,
      email    = common_data$email,
      label    = "",
      correct  = "NA",
      event    = "result",
      data     = '{type":"","binding":"shiny.textInput"}',
      value    = "",
      stringsAsFactors = FALSE)
    res <- rbind(res, fake_result)
  }

  # Sort by date
  res <- res[order(res$date), ]
  res
}

.record_shinylogs <- function(file, url, db, collection = "shiny",
  version = "0", log.errors = TRUE, log.outputs = FALSE, debug = FALSE) {

  if (!file.exists(file))
    return(FALSE)

  dat <- read_shinylogs(file, version = version,
    log.errors = log.errors, log.outputs = log.outputs)

  if (debug)
    message(NROW(dat), " events found in ", file)

  res <- try({
    if (debug)
      message("Connecting to database...")
    m <- mongo(collection = collection, db = db, url = url)
    if (debug)
      message("Inserting events into the database...")
    m$insert(dat)
    if (debug)
      message("...done!")
  }, silent = TRUE)

  if (!inherits(res, "try-error")) {
    unlink(file)
    if (debug)
      message("Successful transfer of data from ", file,
        " to the MongoDB database")
    TRUE
  } else {
    if (debug)
      message("Error while transferring log file ", file, ": ", res)
    FALSE
  }
}

# Test:
# .record_shinylogs("logs/shinylogs_shinylogs_app02_1598274821730014000.rds", url = "mongodb://sdd:sdd@sdd-umons-shard-00-00-umnnw.mongodb.net:27017,sdd-umons-shard-00-01-umnnw.mongodb.net:27017,sdd-umons-shard-00-02-umnnw.mongodb.net:27017/test?ssl=true&replicaSet=sdd-umons-shard-0&authSource=admin", db = "sdd", collection = "shiny", version = "1.0.0")

#' Record Shiny events in a MongoDB database
#'
#' Given a path that contains `shinylogs` events in .rds format, read these
#' events and transfer them into a MongoDB database.
#'
#' @param path The directory that contains shinylogs .rds files
#' @param url The mongodb url.
#' @param db The database name.
#' @param collection The name of the collection where to insert the documents.
#' @param version The version of the running Shiny application.
#' @param log.errors Do we record errors too?
#' @param log.outputs Do we record outputs too (note that results are recorded
#' with inputs)?
#' @param drop.dir If `TRUE` and path is empty at the end of the process, drop
#' the logs directory.
#' @param debug Do we debug the events recording by issuing extra messages?
#'
#' @return `TRUE`if there where log files to export, `FALSE` otherwise.
#' @export
#'
#' @seealso [read_shinylogs()], [trackEvents()]
#'
#' @examples
#' # TODO...
record_shiny <- function(path, url, db, collection = "shiny",
version = "0", log.errors = TRUE, log.outputs = FALSE, drop.dir = FALSE,
debug = FALSE) {
  debug <- isTRUE(debug)
  log_files <- dir(path, pattern = "\\.rds$", full.names = TRUE)
  if (length(log_files)) {
    if (debug)
      message(".rds log file(s) found in ", path, ": ", length(log_files))
    for (file in log_files)
      .record_shinylogs(file, url = url, db = db, collection = collection,
        version = version, log.errors = log.errors, log.outputs = log.outputs,
        debug = debug)
  } else {
    if (debug)
      message("No .rds log file found in ", path)
    return(FALSE)
  }
  if (isTRUE(drop.dir)) {
    if (debug) {
      log_files_remaining <- dir(path, pattern = "\\.rds$")
      message("Remaining log files after transfer to MongoDB: ",
        length(log_files_remaining))
    }
    suppressWarnings(file.remove(path)) # non-empty dir not deleted with warning
  }
  TRUE
}

#' Create and manage learndown Shiny applications
#'
#' A learndown Shiny application is an application whose events (start, stop,
#' inputs, outputs, errors, result, quit) are recorded. It also provides a
#' 'Submit Answer' and a 'Quit' buttons that manage to check the answer provided
#' by the user and to close the application cleanly.
#'
#' @param title The title of the Shiny application
#' @param windowTitle The title of the window that holds the Shiny application,
#' by default, it is the same as `title`. If `title = NULL`, no title is added.
#' @param version The version number (in a string character format) of the Shiny
#' application to use in the events logger.
#' @param inputId The identifier of the button ("submit" or "quit").
#' @param label The button text ("Submit Answer" or "Quit").
#' @param class The bootstrap class of the button.
#' @param ... Further arguments passed to [shiny::actionButton()].
#'
#' @return The code to be inserted at the beginning of the Shiny application UI
#' for [learndownShiny()] or where the buttons should be located for the other
#' function.
#' @export
#'
#' @seealso [trackEvents()], [record_shiny()]
#'
#' @examples
#' learndownShiny("My title")
learndownShiny <- function(title, windowTitle = title) {
  tagList(
    # Required initialisation
    useToastr(),

    # Add a level 4 title (if not NULL)
    if (is.null(title)) NULL else
      tagList(tags$head(tags$title(windowTitle)), h4(title)),

    # Add an hidden input field to contain learndown result
    conditionalPanel(condition = "false", textInput("learndown_result_", ""))
  )
}

#' @export
#' @rdname learndownShiny
learndownShinyVersion <- function(version)
  options(learndown.shiny.version = as.character(version))

#' @export
#' @rdname learndownShiny
submitAnswerButton <- function(inputId = "submit", label = "Submit Answer",
class = "btn-primary", ...)
  actionButton(inputId, label = label, class = class, ...)

#' @export
#' @rdname learndownShiny
quitButton <- function(inputId = "quit", label = "Quit",
class = "btn-secondary", ...)
  actionButton(inputId, label = label, class = class, ...)

#' @export
#' @rdname learndownShiny
submitQuitButtons <- function() {
  fluidRow(
    submitAnswerButton(),
    quitButton()
  )
}

#' Track events, the submit or the quit buttons
#'
#' These functions provide the required code to be inserted in the server part
#' of a Shiny application to track events (start, stop, inputs, outputs, errors,
#' result or quit), to check the answer when the user clicks on the submit
#' button and to cleanly close the application when the user clicks on the quit
#' button.
#'
#' @param session The current Shiny `session`.
#' @param input The Shiny `input` object.
#' @param output The Shiny `output` object.
#' @param url The URL to reach the MongoDB database. By default, it is read from
#' the `MONGO_URL` environment variable.
#' @param url.server The URL to reach the MongoDB database. By default, it is
#' read from the `MONGO_URL_SERVER` environment variable.
#' @param db The database to populate in the MongoDB database. By default, it is
#' read from the `MONGO_BASE` environment variable.
#' @param user The user login to the MongoDB database. By default, it is
#' read from the `MONGO_USER` environment variable.
#' @param password The password to access the MongoDB database. By default, it is
#' read from the `MONGO_PASSWORD` environment variable.
#' @param version The version of the current Shiny application. By default, it
#' is the `learndown.shiny.version` option, as set by [learndownShinyVersion()].
#' @param path The path where the temporary `shinylogs` log files are stored. By
#' default, it is the `shiny_logs` subdirectory of the application,and if that
#' directory is not writable, a temporary directory is used instead.
#' @param log.errors Do we log error events (yes by default)?
#' @param log.outputs Do we log output events (no by default)?
#' @param drop.dir Do we erase the directory indicated by `path =` if it is
#' empty at the end of the process (yes by default).
#' @param debug Do we debug recording of events using extra messages?
#' @param solution The correct solution as a named list. Names are the
#' application inputs to check and their values are the correct values. The
#' current state of these inputs will be compared against the solution, and the
#' `message.success` or `message.error` is displayed accordingly. Also a result
#' event is triggered with the `correct` field set to `TRUE` or `FALSE`
#' accordingly. If `solution = NULL`, then the answer is considered to be always
#' correct (use this if you just want to indicate that the user's answer is
#' recorded in the database).
#' @param comment A string with a comment to append to the value of the result
#' event.
#' @param message.success The message to display is the answer is correct
#' ("Correct" by default).
#' @param message.error The message to display if the answer is wrong
#' ("Incorrect" by default).
#' @param delay The time to wait before we close the Shiny application in sec
#' (60 sec by default). If `delay = -1`, the application is **not** closed, only
#' the session is closed when the user clicks on the quit button.
#'
#' @return The code to be inserted in the server part of the learndown Shiny
#' application in order to properly identify the user and record the events.
#' @export
#'
#' @seealso [learndownShinyVersion()]
#'
#' @examples
#' # TODO...
trackEvents <- function(session, input, output,
url = Sys.getenv("MONGO_URL"), url.server = Sys.getenv("MONGO_URL_SERVER"),
db = Sys.getenv("MONGO_BASE"), user = Sys.getenv("MONGO_USER"),
password = Sys.getenv("MONGO_PASSWORD"),
version = getOption("learndown.shiny.version"), path = "shiny_logs",
log.errors = TRUE, log.outputs = FALSE, drop.dir = TRUE, debug = FALSE) {

  # Indicate this is a learndown Shiny application
  if (isTRUE(debug))
    message("Shiny application with learndown v. ", packageVersion("learndown"))

  # Increment a session counter
  session_counter <- getOption("learndown.shiny.sessions", default = 0) + 1
  options(learndown.shiny.sessions = session_counter)
  message("Running sessions: ", session_counter)

  # Install callbacks on session close
  observe({
    # Decrement the number of opened sessions on session close
    onSessionEnded(function() {
      session_counter <- getOption("learndown.shiny.sessions", default = 0) - 1
      options(learndown.shiny.sessions = session_counter)
      message("Running sessions: ", session_counter)
    })

    # Get user information
    user_info <- parseQueryString(session$clientData$url_search)
    # If there is no login in user_info, we don't track events
    if (is.null(user_info$login)) {
      message("No login: no events will be tracked")
      toastr_warning("Utilisateur anonyme, aucun enregistrement.",
        closeButton = TRUE, position = "top-right", showDuration = 5)
    } else {
      # Check that 'path' exists and is writeable, or use a temporary directory
      if (!dir.exists(path))
        dir.create(path, showWarnings = FALSE, recursive = TRUE)
      test_file <- file.path(path, "test.txt")
      res <- try(cat("test, can be deleted", file = test_file), silent = TRUE)
      # Switch to a temporary directory, if it is not there, or not writeable
      if (inherits(res, "try-error") || !file.exists(test_file))
        path <- file.path(tempdir(check = TRUE), session$token)
      unlink(test_file)

      message("Tracking events in ", path, " for user ", user_info$login)
      toastr_info(paste("Enregistrement actif pour", user_info$login),
        closeButton = TRUE, position = "top-right", showDuration = 5)
      updateActionButton(session, "quit", label = "Save/Quit")

      user_tracking <- function(session, query = user_info) {
        # This is the original shinylogs function to retrieve the user
        get_user <- function(session) {
          if (!is.null(session$user))
            return(session$user)
          shiny_user <- Sys.getenv("SHINYPROXY_USERNAME")
          if (shiny_user != "") {
            return(shiny_user)
          } else {
            getOption("shinylogs.default_user", default = Sys.info()[['user']])
          }
        }
        shiny_user <- get_user(session)

        if (!length(query)) {
          query <- list(user = shiny_user)
        } else {
          query$user <- shiny_user
        }
        as.character(toJSON(query, auto_unbox = TRUE))
      }

      track_usage(storage_mode = store_rds(path = path),
        get_user = user_tracking)

      url <- glue(url) # User and password replaced in the URL
      url.server <- glue(url.server)

      onSessionEnded(function() {
        # Read log events from .rds files and insert them in a MongoDB database
        # If MONGO_URL_SERVER exists and we are run from a server, we use it,
        # otherwise, we use MONGO_URL
        is_local <- function()
          Sys.getenv('SHINY_PORT') == ""

        is_server_up <- function(url, db) {
          res <- try(mongo(collection = "shiny", db = db), silent = TRUE)
          !inherits(res, "try-error")
        }

        if (is_local()) {
          if (isTRUE(debug))
            message("Application runs locally")
          # We use url
        } else {
          if (isTRUE(debug))
            message("Application runs from a server")
          if (url.server != "" && is_server_up(url = url.server, db = db))
            url <- url.server # Use server URL instead
        }
        if (isTRUE(debug))
          message("Database URL: ", url, ", base: ", db)
        record_shiny(path, url = url, db = db,
          version = version, log.errors = log.errors, log.outputs = log.outputs,
          drop.dir = drop.dir, debug = debug)
      })
    }
  })
}

.shiny_feedback <- function(success = TRUE, message.success, message.error,
  position = "bottom-center") {
  #myToastOptions <- list(
  #  positionClass = "toast-bottom-center",
  #  progressBar = FALSE,
  #  closeButton = TRUE)

  if (isTRUE(success)) {
    #showToast("success", message.success, .options = myToastOptions)
    toastr_success(message.success, closeButton = TRUE, position = position)
  } else {
    #showToast("error", message.error, .options = myToastOptions)
    toastr_error(message.error, closeButton = TRUE, position = position)
  }
}

#' @export
#' @rdname trackEvents
trackSubmit <- function(session, input, output, solution = NULL, comment = "",
  message.success = "Correct", message.error = "Incorrect") {
  observeEvent(input$submit, {
    req(input$submit)

    if (is.null(solution)) {
      # Always TRUE
      res <- TRUE
    } else {
      items <- names(solution)
      answer <- list()
      if (length(items))
        for (item in items)
          answer[[item]] <- isolate(input[[item]])
      res <- isTRUE(all.equal(answer, solution, check.attributes = FALSE))
    }
    .shiny_feedback(res,
      message.success = message.success,
      message.error = message.error)
    val <- list(
      correct = res,
      answer = answer,
      solution = solution,
      comment = comment
    )
    val_str <- as.character(toJSON(val, auto_unbox = TRUE))
    updateTextInput(session, "learndown_result_", value = val_str)
  })
}

#' @export
#' @rdname trackEvents
trackQuit <- function(session, input, output, delay = 60) {
  observeEvent(input$quit, {
    req(input$quit)
    session$close()
    # Force closing the app after delay if there is no other opened session
    if (delay != -1)
      later::later(function() {
        if (getOption("learndown.shiny.sessions", default = 2) < 1)
          stopApp()
      }, delay = delay)
  })
}