/**
 * Rider identity verification — compares the face on the uploaded ID to a live
 * selfie via AWS Rekognition CompareFaces. Anti-fraud gate before a rider can
 * request trips.
 *
 *   ≥ 85% similarity → auto-approved
 *   60–84%           → pending (manual admin review)
 *   < 60%            → rejected (retry)
 *
 * AWS creds live in Functions Secrets (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY).
 * Images are read from Storage at verifications/{uid}/id.jpg + selfie.jpg.
 */
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const logger = require("firebase-functions/logger");
const admin = require("firebase-admin");
const {
  RekognitionClient,
  CompareFacesCommand,
} = require("@aws-sdk/client-rekognition");

const AWS_ACCESS_KEY_ID = defineSecret("AWS_ACCESS_KEY_ID");
const AWS_SECRET_ACCESS_KEY = defineSecret("AWS_SECRET_ACCESS_KEY");

const REGION = "europe-west1";
const AWS_REGION = "us-east-1";
const AUTO_APPROVE = 85;
const REVIEW_FLOOR = 60;

const db = () => admin.firestore();

exports.verifyRiderIdentity = onCall(
  { region: REGION, secrets: [AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY] },
  async (req) => {
    const uid = req.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");

    const bucket = admin.storage().bucket();
    let idBytes;
    let selfieBytes;
    try {
      [idBytes] = await bucket.file(`verifications/${uid}/id.jpg`).download();
      [selfieBytes] = await bucket
        .file(`verifications/${uid}/selfie.jpg`)
        .download();
    } catch (_) {
      throw new HttpsError("not-found", "Upload your ID and selfie first.");
    }

    const client = new RekognitionClient({
      region: AWS_REGION,
      credentials: {
        accessKeyId: AWS_ACCESS_KEY_ID.value(),
        secretAccessKey: AWS_SECRET_ACCESS_KEY.value(),
      },
    });

    let similarity = 0;
    try {
      const res = await client.send(
        new CompareFacesCommand({
          // The ID photo is the reference; the live selfie is compared to it.
          SourceImage: { Bytes: idBytes },
          TargetImage: { Bytes: selfieBytes },
          SimilarityThreshold: 0,
          QualityFilter: "AUTO",
        })
      );
      similarity = res.FaceMatches?.[0]?.Similarity || 0;
    } catch (e) {
      logger.warn("CompareFaces failed", { uid, name: e?.name, msg: e?.message });
      throw new HttpsError(
        "failed-precondition",
        "We couldn't clearly see a face on your ID or selfie. Retake them in good light."
      );
    }

    const score = Math.round(similarity * 10) / 10;
    const status =
      similarity >= AUTO_APPROVE
        ? "approved"
        : similarity >= REVIEW_FLOOR
          ? "pending"
          : "rejected";

    await db().collection("users").doc(uid).set(
      {
        verificationStatus: status,
        faceMatchScore: score,
        verifiedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    logger.info("rider verification", { uid, score, status });
    return { status, score };
  }
);
