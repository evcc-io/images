get_available_boards() {
  BOARDLIST=()
  FILES="userpatches/config-*.conf.sh"
  for f in $FILES
  do
    if [[ "$f" =~ userpatches/config-([A-Za-z0-9\-]+)\.conf\.sh ]]; then
      BOARDLIST+=(${BASH_REMATCH[1]})
    fi
  done
}
