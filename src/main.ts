import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  const port = Number(process.env.PORT) || 3000;
  // Listen on localhost only: nginx is the public entry point on port 80
  await app.listen(port, '127.0.0.1');
  console.log(`API started on 127.0.0.1:${port}`);
}
bootstrap();
