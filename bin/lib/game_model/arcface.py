# bin/game-model's face gate: ArcFace (insightface buffalo_l) embeddings, run on
# the operator's Mac by his ruling (2026-10-18), never on a dyno.
#
#   python arcface.py embed <out.json> <image>...
#       the largest face in each image -> its normed embedding (null when none)
#   python arcface.py find <out.json> <ref.jpg,ref.jpg,...> <image>...
#       every face in each image, scored against the mean of the ref faces
#
# Measured on three players (Nix, Darnold, Williams): real photos of the man
# score 0.39-0.87 against his own faces, other men <= 0.31. A generated face
# below about 0.70 has always looked wrong; above it the score does not rank.
import json
import sys

import cv2
import numpy as np
from insightface.app import FaceAnalysis


def analyser(size):
    app = FaceAnalysis(name="buffalo_l", providers=["CPUExecutionProvider"],
                       allowed_modules=["detection", "recognition"])
    app.prepare(ctx_id=-1, det_size=(size, size))
    return app


def largest(faces):
    return max(faces, key=lambda f: (f.bbox[2] - f.bbox[0]) * (f.bbox[3] - f.bbox[1]))


def embed(app, path):
    img = cv2.imread(path)
    if img is None:
        return None
    faces = app.get(img)
    if not faces:
        # A tight crop leaves the detector no margin; grey padding gives it one.
        faces = app.get(cv2.copyMakeBorder(img, 200, 200, 200, 200, cv2.BORDER_CONSTANT, value=(128, 128, 128)))
    return largest(faces).normed_embedding if faces else None


def main(argv):
    mode, out = argv[1], argv[2]
    app = analyser(640)
    if mode == "embed":
        result = {}
        for path in argv[3:]:
            vec = embed(app, path)
            result[path] = None if vec is None else vec.tolist()
    elif mode == "find":
        refs = [v for v in (embed(app, p) for p in argv[3].split(",")) if v is not None]
        if not refs:
            sys.exit("arcface find: no face found in any reference")
        centre = np.mean(refs, axis=0)
        centre /= np.linalg.norm(centre)
        big = analyser(1024)
        result = []
        for path in argv[4:]:
            img = cv2.imread(path)
            if img is None:
                continue
            for face in big.get(img):
                box = [int(x) for x in face.bbox]
                result.append({"file": path, "score": float(face.normed_embedding @ centre),
                               "bbox": box, "h": box[3] - box[1]})
    else:
        sys.exit("arcface: mode must be embed or find")
    with open(out, "w") as handle:
        json.dump(result, handle)


if __name__ == "__main__":
    main(sys.argv)
