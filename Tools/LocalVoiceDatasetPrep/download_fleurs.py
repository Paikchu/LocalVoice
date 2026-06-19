#!/usr/bin/env python3
import argparse
import json
import math
import pathlib
import re
import sys
import wave


DATASET = "google/fleurs"
CONFIG = "cmn_hans_cn"
LICENSE = "CC-BY-4.0"


def parse_args():
    parser = argparse.ArgumentParser(
        description="Download a small FLEURS zh_cn benchmark slice for LocalVoice."
    )
    parser.add_argument("--suite", choices=["smoke", "full"], default="smoke")
    parser.add_argument("--limit", type=int, default=None)
    parser.add_argument("--split", default="test")
    parser.add_argument(
        "--output",
        default="benchmark-data/fleurs-zh_cn",
        help="Output directory for audio and manifest files.",
    )
    return parser.parse_args()


def load_dataset_or_exit(split):
    try:
        from datasets import Audio, load_dataset
    except ImportError:
        print(
            "Missing dependency: install with `python3 -m pip install datasets`.",
            file=sys.stderr,
        )
        sys.exit(2)

    dataset = load_dataset(DATASET, CONFIG, split=split, streaming=True)
    return dataset.cast_column("audio", Audio(decode=True))


def write_wav(path, samples, sample_rate):
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(int(sample_rate))
        frames = bytearray()
        for value in samples:
            clipped = max(-1.0, min(1.0, float(value)))
            frames.extend(int(clipped * 32767).to_bytes(2, "little", signed=True))
        wav.writeframes(frames)


def normalize_fact(text):
    tokens = re.findall(r"[A-Za-z0-9][A-Za-z0-9._:/-]*", text)
    return tokens[:3]


def semantic_groups(text):
    normalized = re.sub(r"\s+", "", text)
    if not normalized:
        return []
    size = max(2, math.ceil(len(normalized) / 3))
    return [[normalized[index : index + size]] for index in range(0, len(normalized), size)][:3]


def sample_id(index):
    return f"fleurs-zh_cn-{index + 1:04d}"


def main():
    args = parse_args()
    limit = args.limit if args.limit is not None else (15 if args.suite == "smoke" else 80)
    root = pathlib.Path(args.output)
    audio_dir = root / "audio" / args.suite
    manifest_path = root / f"{args.suite}.jsonl"

    dataset = load_dataset_or_exit(args.split)
    rows = []
    for index, item in enumerate(dataset):
        if index >= limit:
            break
        audio = item["audio"]
        text = item.get("transcription") or item.get("raw_transcription") or ""
        case_id = sample_id(index)
        audio_path = audio_dir / f"{case_id}.wav"
        write_wav(audio_path, audio["array"], audio["sampling_rate"])
        rows.append(
            {
                "id": case_id,
                "suite": args.suite,
                "audioPath": str(audio_path),
                "verbatimReference": text,
                "mode": "dictation",
                "expectedIntent": "plainText",
                "requiredFacts": normalize_fact(text),
                "forbiddenClaims": [],
                "semanticGroups": semantic_groups(text),
                "terms": normalize_fact(text),
                "audioTags": ["public", "fleurs", args.split],
                "sourceDataset": f"{DATASET} {CONFIG} {args.split}",
                "sourceLicense": LICENSE,
            }
        )

    root.mkdir(parents=True, exist_ok=True)
    with manifest_path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")

    print(f"Wrote {len(rows)} cases to {manifest_path}")


if __name__ == "__main__":
    main()
