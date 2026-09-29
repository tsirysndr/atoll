import { z } from "zod";

const identifier = z
  .string()
  .trim()
  .min(1, "Enter your username or email address")
  .max(2048, "That identifier is too long");

const password = z
  .string()
  .min(8, "Passwords are at least 8 characters")
  .max(1024, "That password is too long");

const totpCode = z
  .string()
  .trim()
  .regex(/^(?:[0-9]{6}|[A-Z2-7]{26})$/, "Enter a 6-digit code or a recovery code")
  .or(z.literal(""));

const emailCode = z
  .string()
  .trim()
  .length(32, "Sign-in codes are 32 characters")
  .or(z.literal(""));

export const loginSchema = z.object({
  identifier,
  password,
  authFactorToken: emailCode.optional(),
  totpCode: totpCode.optional(),
});

export type LoginValues = z.infer<typeof loginSchema>;

export const signupSchema = z
  .object({
    handle: z
      .string()
      .trim()
      .min(1, "Choose a username")
      .max(253, "That username is too long")
      .regex(/^[a-zA-Z0-9.-]+$/, "Use letters, numbers, hyphens and dots only"),
    email: z.email("Enter a valid email address").max(320).or(z.literal("")),
    password,
    confirmPassword: z.string().min(1, "Confirm your password"),
    inviteCode: z.string().trim().max(256).or(z.literal("")),
  })
  .refine((values) => values.password === values.confirmPassword, {
    message: "Those passwords do not match",
    path: ["confirmPassword"],
  });

export type SignupValues = z.infer<typeof signupSchema>;

export const passwordOnlySchema = z.object({ password });

export type PasswordOnlyValues = z.infer<typeof passwordOnlySchema>;

export const totpSchema = z.object({
  totpCode: z
    .string()
    .trim()
    .regex(/^(?:[0-9]{6}|[A-Z2-7]{26})$/, "Enter a 6-digit code or a recovery code"),
});

export type TotpValues = z.infer<typeof totpSchema>;

export const passkeyNameSchema = z.object({
  name: z.string().trim().min(1, "Name this passkey").max(64, "That name is too long"),
  password,
  totpCode: totpCode.optional(),
});

export type PasskeyNameValues = z.infer<typeof passkeyNameSchema>;
