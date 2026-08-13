# Require non-blocking handlers

Ploof handlers will run to completion on their owning worker and must not block.
Version one will provide an explicit bounded offload path for blocking database,
filesystem, CPU, or legacy work: fixed helper threads consume preallocated job
slots and return completions to the originating worker. Ploof will not create a
thread or fiber per request. This makes blocking visible while preventing one
slow operation from stalling every connection in a worker shard.
