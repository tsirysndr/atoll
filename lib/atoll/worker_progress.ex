defmodule Atoll.WorkerProgress do
  @moduledoc "Reports when a scheduled worker must next make progress, including its task timeout."

  def scheduled(worker, delay_ms, timeout_ms)
      when is_binary(worker) and is_integer(delay_ms) and delay_ms >= 0 and
             is_integer(timeout_ms) and timeout_ms >= 0 do
    deadline = div(System.system_time(:millisecond) + delay_ms + timeout_ms + 999, 1000)

    :telemetry.execute([:atoll, :worker, :scheduled], %{deadline_seconds: deadline}, %{
      worker: worker
    })
  end
end
