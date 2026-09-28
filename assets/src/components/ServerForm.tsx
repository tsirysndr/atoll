import { useRef, type FormEvent, type ReactNode } from "react";
import type { FieldValues, UseFormReturn } from "react-hook-form";

export type ServerFormApi = {
  formRef: React.RefObject<HTMLFormElement | null>;
  onSubmit: (event: FormEvent<HTMLFormElement>) => void;
  submitWith: (name: string, value: string) => void;
};

export function useServerForm<T extends FieldValues>(form: UseFormReturn<T>): ServerFormApi {
  const formRef = useRef<HTMLFormElement>(null);
  const intent = useRef<{ name: string; value: string } | null>(null);

  const submitNative = () => {
    const element = formRef.current;
    if (!element) return;

    if (intent.current) {
      const input = document.createElement("input");
      input.type = "hidden";
      input.name = intent.current.name;
      input.value = intent.current.value;
      element.appendChild(input);
    }

    element.submit();
  };

  return {
    formRef,
    onSubmit: form.handleSubmit(submitNative),
    submitWith: (name, value) => {
      intent.current = { name, value };
    },
  };
}

export type ServerFormProps = {
  action: string;
  csrf: string;
  api: ServerFormApi;
  hidden?: Record<string, string | null | undefined>;
  className?: string;
  children: ReactNode;
};

export function ServerForm({
  action,
  csrf,
  api,
  hidden = {},
  className = "flex flex-col gap-4",
  children,
}: ServerFormProps) {
  return (
    <form
      ref={api.formRef}
      method="post"
      action={action}
      onSubmit={api.onSubmit}
      noValidate
      className={className}
    >
      <input type="hidden" name="_csrf_token" value={csrf} />
      {Object.entries(hidden).map(([name, value]) =>
        value == null ? null : <input key={name} type="hidden" name={name} value={value} />,
      )}
      {children}
    </form>
  );
}
