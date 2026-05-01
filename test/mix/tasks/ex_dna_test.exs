defmodule Mix.Tasks.ExDnaTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Error
  alias Mix.Tasks.ExDna

  setup do
    dir = Path.join(System.tmp_dir!(), "ex_dna_task_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "raises a Mix error when clones exceed the budget", %{dir: dir} do
    write_duplicate_pair(dir)

    output =
      capture_io(fn ->
        error =
          assert_raise Error, fn ->
            ExDna.run(["--min-mass", "5", dir])
          end

        assert Exception.message(error) =~ "ExDNA found"
      end)

    assert output =~ "code duplication report"
  end

  test "does not raise when clones are within the configured budget", %{dir: dir} do
    write_duplicate_pair(dir)

    capture_io(fn ->
      assert is_nil(ExDna.run(["--min-mass", "5", "--max-clones", "10", dir]))
    end)
  end

  test "does not raise when file is ignored in config", %{dir: dir} do
    write_duplicate_pair(dir)

    capture_io(fn ->
      File.cd!(dir, fn() ->
        File.write!(Path.join(dir, ".ex_dna.exs"), ~s/%{ignore: ["b.ex"]}/)
        assert is_nil(ExDna.run(["--min-mass", "5", dir]))
      end)
    end)
  end

  defp write_duplicate_pair(dir) do
    File.write!(Path.join(dir, "a.ex"), duplicate_module("A"))
    File.write!(Path.join(dir, "b.ex"), duplicate_module("B"))
  end

  defp duplicate_module(name) do
    """
    defmodule #{name} do
      def process(data) do
        data
        |> Enum.map(fn x -> x * 2 end)
        |> Enum.filter(fn x -> x > 10 end)
        |> Enum.sort()
        |> Enum.take(5)
      end
    end
    """
  end
end
