interface User { id: number; name: string }
export const greet = (u: User): string => `hi ${u.name}`;
