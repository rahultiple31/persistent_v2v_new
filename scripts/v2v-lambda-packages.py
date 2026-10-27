"""Build prebuilt Lambda ZIPs and transfer deployment ZIPs with a saved plan."""

import argparse
from pathlib import Path
import shutil
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo


CONNECT_DIRECTORIES = (
    "scr_lambda",
    "BTSGSD-lex-QueueFlow-Callback-dev_lambda",
    "BTSGSD-lex-yesNo-dev_lambda-dev_lambda",
    "conversionOfQueueMetrics-dev_lambda",
)
WARMUP_WRAPPER = (
    Path(__file__).resolve().parents[1]
    / "v2v_modules/UpdateSessionAttributes-dev/warmup_wrapper.py"
)


def build(state_module, working_directory):
    if state_module != "connect":
        return
    for directory in CONNECT_DIRECTORIES:
        source = working_directory / "metadata" / directory / "lambda_function.py"
        sources = {"lambda_function.py": source}
        if directory == "scr_lambda":
            sources["warmup_wrapper.py"] = WARMUP_WRAPPER
        for path in sources.values():
            if not path.is_file():
                raise FileNotFoundError("Missing Lambda source: " + str(path))
        with ZipFile(source.with_suffix(".zip"), "w") as package:
            for name, path in sources.items():
                # Stable metadata prevents checkout timestamps from changing the hash.
                entry = ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                entry.compress_type = ZIP_DEFLATED
                entry.create_system = 3
                entry.external_attr = 0o100644 << 16
                package.writestr(entry, path.read_bytes())


def transfer(source_directory, destination_directory):
    for source in sorted((source_directory / "metadata").rglob("*.zip")):
        destination = destination_directory / source.relative_to(source_directory)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    builder = commands.add_parser("build")
    builder.add_argument("--state-module", required=True)
    for command in ("save", "restore"):
        commands.add_parser(command).add_argument(
            "--artifact-directory", type=Path, required=True
        )
    args = parser.parse_args()
    working_directory = Path.cwd()
    if args.command == "build":
        build(args.state_module, working_directory)
    elif args.command == "save":
        transfer(working_directory, args.artifact_directory)
    else:
        transfer(args.artifact_directory, working_directory)


if __name__ == "__main__":
    main()
