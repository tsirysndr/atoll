import { useState } from "react";
import { Button, Input } from "@heroui/react";
import { IconEye, IconEyeOff } from "@tabler/icons-react";
import type { FieldError, UseFormRegisterReturn } from "react-hook-form";

export type FieldProps = {
  label: string;
  placeholder?: string;
  description?: React.ReactNode;
  error?: FieldError;
  registration: UseFormRegisterReturn;
  type?: string;
  autoComplete?: string;
  autoFocus?: boolean;
  maxLength?: number;
  inputMode?: "text" | "email" | "numeric";
  endContent?: React.ReactNode;
  startContent?: React.ReactNode;
  isRequired?: boolean;
};

const inputClassNames = {
  inputWrapper:
    "h-12 rounded-md border border-default-200 bg-default-50/60 data-[hover=true]:border-default-300 group-data-[focus=true]:border-primary",
  label: "text-sm font-medium text-foreground",
  input: "text-base",
};

export function TextField({
  label,
  placeholder,
  description,
  error,
  registration,
  type = "text",
  autoComplete,
  autoFocus,
  maxLength,
  inputMode,
  endContent,
  startContent,
  isRequired = true,
}: FieldProps) {
  return (
    <Input
      {...registration}
      label={label}
      placeholder={placeholder}
      description={description}
      type={type}
      variant="bordered"
      radius="sm"
      labelPlacement="outside"
      autoComplete={autoComplete}
      autoFocus={autoFocus}
      maxLength={maxLength}
      inputMode={inputMode}
      endContent={endContent}
      startContent={startContent}
      isRequired={isRequired}
      isInvalid={Boolean(error)}
      errorMessage={error?.message}
      autoCapitalize="none"
      spellCheck="false"
      classNames={inputClassNames}
    />
  );
}

export function PasswordField(props: Omit<FieldProps, "type">) {
  const [visible, setVisible] = useState(false);

  return (
    <TextField
      {...props}
      type={visible ? "text" : "password"}
      endContent={
        <Button
          isIconOnly
          size="sm"
          variant="light"
          radius="full"
          aria-label={visible ? "Hide password" : "Show password"}
          onPress={() => setVisible((value) => !value)}
          className="-mr-1 text-default-400"
        >
          {visible ? <IconEyeOff size={18} stroke={1.75} /> : <IconEye size={18} stroke={1.75} />}
        </Button>
      }
    />
  );
}
