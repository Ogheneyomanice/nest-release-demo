import { Injectable } from '@nestjs/common';
import { readFileSync } from 'fs';
import { join } from 'path';
import { hostname } from 'os';

@Injectable()
export class AppService {
  // The version comes from the package.json that is shipped inside each release folder
  private readonly version: string = JSON.parse(
    readFileSync(join(__dirname, '..', 'package.json'), 'utf8'),
  ).version;
  private readonly startedAt = new Date().toISOString();

  getVersion(): string {
    return this.version;
  }

  getInfo() {
    return {
      name: 'nest-release-demo',
      version: this.version,
      host: hostname(),
      startedAt: this.startedAt,
    };
  }

  getProducts() {
  throw new Error('Products service is broken in 1.2.0');
}

  getUsers() {
    return [
      { id: 1, name: 'Ada' },
      { id: 2, name: 'Tunde' },
      { id: 3, name: 'Ngozi' },
    ];
  }
}
