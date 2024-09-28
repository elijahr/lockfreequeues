


template log*(msg: string) =
  echo "[" & $getThreadId() & "]: " & msg
