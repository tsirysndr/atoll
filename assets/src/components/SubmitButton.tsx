import { useState, type ReactNode } from "react";
import { Button, type ButtonProps } from "@heroui/react";

export type SubmitButtonProps = ButtonProps & { children: ReactNode };

export function SubmitButton({ children, ...props }: SubmitButtonProps) {
  return (
    <Button type="submit" radius="sm" spinnerPlacement="start" {...props}>
      {children}
    </Button>
  );
}

export type PostFormProps = {
  action: string;
  csrf: string;
  fields?: Record<string, string>;
  className?: string;
  children: (submitting: boolean) => ReactNode;
};

/** A form that posts straight to the server, showing progress while it navigates. */
export function PostForm({ action, csrf, fields = {}, className, children }: PostFormProps) {
  const [submitting, setSubmitting] = useState(false);

  return (
    <form
      method="post"
      action={action}
      className={className}
      onSubmit={() => setSubmitting(true)}
    >
      <input type="hidden" name="_csrf_token" value={csrf} />
      {Object.entries(fields).map(([name, value]) => (
        <input key={name} type="hidden" name={name} value={value} />
      ))}
      {children(submitting)}
    </form>
  );
}
